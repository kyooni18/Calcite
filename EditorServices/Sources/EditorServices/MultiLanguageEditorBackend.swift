import EditorCore
import EditorLSP
import EditorServiceKit
import EditorTreeSitter
import EditorWorkspace
import Foundation

#if os(macOS) || os(Linux)
  /// A local stdio language server and the documents that should be routed to it.
  public struct ExternalLanguageServerConfiguration: Sendable {
    public var id: LanguageServiceID
    public var process: LSPProcessConfiguration
    public var selector: LanguageServiceSelector
    public var role: LanguageServiceRole
    public var priority: Int
    public var eagerlyInitialize: Bool
    public var automaticallyApplyWorkspaceEdits: Bool
    public var configurationProvider: LSPDocumentService.ConfigurationProvider

    public init(
      id: LanguageServiceID,
      process: LSPProcessConfiguration,
      selector: LanguageServiceSelector,
      role: LanguageServiceRole = .primary,
      priority: Int = 0,
      eagerlyInitialize: Bool = true,
      automaticallyApplyWorkspaceEdits: Bool = true,
      configurationProvider: @escaping LSPDocumentService.ConfigurationProvider = { items in
        Array(repeating: .null, count: items.count)
      }
    ) {
      self.id = id
      self.process = process
      self.selector = selector
      self.role = role
      self.priority = priority
      self.eagerlyInitialize = eagerlyInitialize
      self.automaticallyApplyWorkspaceEdits = automaticallyApplyWorkspaceEdits
      self.configurationProvider = configurationProvider
    }
  }

  /// Complete configuration for a workspace containing multiple programming languages.
  public struct MultiLanguageEditorBackendConfiguration: Sendable {
    public var workspaceURL: URL
    public var defaultLanguageID: String
    public var languageCatalog: EditorLanguageCatalog
    public var languageServers: [ExternalLanguageServerConfiguration]
    public var treeSitterRegistry: TreeSitterLanguageRegistry?
    public var enableLexicalSyntaxFallback: Bool
    public var completionStrategy: SwiftEditorCompletionStrategy
    public var completionLimit: Int
    public var sourceWorkspaceConfiguration: SourceWorkspaceConfiguration
    public var processEnvironment: [String: String]
    public var scanSourceWorkspaceOnConstruction: Bool
    public var sourceWorkspaceMonitoringInterval: Duration?
    public var languageServerInitializationTimeout: Duration?
    public var languageServerShutdownTimeout: Duration

    public init(
      workspaceURL: URL,
      defaultLanguageID: String = "plaintext",
      languageCatalog: EditorLanguageCatalog = .standard,
      languageServers: [ExternalLanguageServerConfiguration] = [],
      treeSitterRegistry: TreeSitterLanguageRegistry? = nil,
      enableLexicalSyntaxFallback: Bool = true,
      completionStrategy: SwiftEditorCompletionStrategy = .languageServerOnly,
      completionLimit: Int = 100,
      sourceWorkspaceConfiguration: SourceWorkspaceConfiguration = .init(),
      processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
      scanSourceWorkspaceOnConstruction: Bool = true,
      sourceWorkspaceMonitoringInterval: Duration? = nil,
      languageServerInitializationTimeout: Duration? = .seconds(15),
      languageServerShutdownTimeout: Duration = .seconds(5)
    ) {
      self.workspaceURL = workspaceURL
      self.defaultLanguageID = defaultLanguageID
      self.languageCatalog = languageCatalog
      self.languageServers = languageServers
      self.treeSitterRegistry = treeSitterRegistry
      self.enableLexicalSyntaxFallback = enableLexicalSyntaxFallback
      self.completionStrategy = completionStrategy
      self.completionLimit = max(1, completionLimit)
      self.sourceWorkspaceConfiguration = sourceWorkspaceConfiguration
      self.processEnvironment = processEnvironment
      self.scanSourceWorkspaceOnConstruction = scanSourceWorkspaceOnConstruction
      self.sourceWorkspaceMonitoringInterval = sourceWorkspaceMonitoringInterval
      self.languageServerInitializationTimeout = languageServerInitializationTimeout
      self.languageServerShutdownTimeout = languageServerShutdownTimeout
    }
  }

  public enum ExternalLanguageServerStartupStage: String, Hashable, Codable, Sendable {
    case executableResolution
    case processLaunch
    case initialization
  }

  /// Identifies exactly which external server failed and at which startup stage.
  public struct ExternalLanguageServerStartupError: Error, Hashable, Sendable {
    public var serviceID: LanguageServiceID
    public var executable: String
    public var stage: ExternalLanguageServerStartupStage
    public var underlyingDescription: String

    public init(
      serviceID: LanguageServiceID,
      executable: String,
      stage: ExternalLanguageServerStartupStage,
      underlyingDescription: String
    ) {
      self.serviceID = serviceID
      self.executable = executable
      self.stage = stage
      self.underlyingDescription = underlyingDescription
    }
  }

  extension ExternalLanguageServerStartupError: LocalizedError {
    public var errorDescription: String? {
      "Language server '\(serviceID)' failed during \(stage.rawValue): \(underlyingDescription)"
    }

    public var recoverySuggestion: String? {
      switch stage {
      case .executableResolution:
        return "Install the server, add it to PATH, or provide an absolute executable path."
      case .processLaunch:
        return
          "Check executable permissions, launch arguments, environment variables, and working directory."
      case .initialization:
        return
          "Inspect the server log and verify that the workspace and initialization options are valid."
      }
    }
  }

  public enum MultiLanguageBackendConfigurationError: Error, Hashable, Sendable {
    case emptyLanguageServerID
    case duplicateLanguageServerID(LanguageServiceID)
  }

  extension MultiLanguageBackendConfigurationError: LocalizedError {
    public var errorDescription: String? {
      switch self {
      case .emptyLanguageServerID:
        return "A language-server registration has an empty identifier."
      case .duplicateLanguageServerID(let id):
        return "The language-server identifier is registered more than once: \(id)."
      }
    }
  }

  extension SwiftEditorBackend {
    /// Constructs a backend that routes each document to matching LSP and Tree-sitter services.
    ///
    /// Every server uses the standard Language Server Protocol over stdio. Servers are independent:
    /// Python, C/C++, Rust, TypeScript, and other documents can be open in one backend at once.
    public static func makeMultiLanguage(
      configuration: MultiLanguageEditorBackendConfiguration
    ) async throws -> SwiftEditorBackend {
      let contextualSyntaxFactory: SwiftEditorBackend.ContextualSyntaxFactory?
      if configuration.treeSitterRegistry != nil || configuration.enableLexicalSyntaxFallback {
        contextualSyntaxFactory = { context in
          let primary = try configuration.treeSitterRegistry?.makeService(
            uri: context.uri,
            languageID: context.languageID
          )
          if configuration.enableLexicalSyntaxFallback {
            return ResilientSyntaxService(primary: primary, languageID: context.languageID)
          }
          return primary
        }
      } else {
        contextualSyntaxFactory = nil
      }

      var sourceWorkspaceConfiguration = configuration.sourceWorkspaceConfiguration
      sourceWorkspaceConfiguration.languageCatalog = configuration.languageCatalog

      var builder = EditorBackendBuilder(
        workspaceURL: configuration.workspaceURL,
        languageID: configuration.defaultLanguageID,
        contextualSyntaxFactory: contextualSyntaxFactory,
        completionStrategy: configuration.completionStrategy,
        completionLimit: configuration.completionLimit,
        sourceWorkspaceConfiguration: sourceWorkspaceConfiguration,
        processEnvironment: configuration.processEnvironment,
        scanSourceWorkspaceOnConstruction: configuration.scanSourceWorkspaceOnConstruction,
        sourceWorkspaceMonitoringInterval: configuration.sourceWorkspaceMonitoringInterval
      )

      // Resolve every executable before launching any process. This avoids partially started
      // workspaces and turns a generic process error into a service-specific configuration error.
      var registeredIDs = Set<LanguageServiceID>()
      for server in configuration.languageServers {
        guard !server.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw MultiLanguageBackendConfigurationError.emptyLanguageServerID
        }
        guard registeredIDs.insert(server.id).inserted else {
          throw MultiLanguageBackendConfigurationError.duplicateLanguageServerID(server.id)
        }
      }

      var preparedServers: [ExternalLanguageServerConfiguration] = []
      for server in configuration.languageServers {
        do {
          var prepared = server
          prepared.process.executable = try LSPExecutableResolver.resolve(
            server.process.executable,
            environment: server.process.environment
          )
          preparedServers.append(prepared)
        } catch {
          throw ExternalLanguageServerStartupError(
            serviceID: server.id,
            executable: server.process.executable,
            stage: .executableResolution,
            underlyingDescription: error.localizedDescription
          )
        }
      }

      let shutdownTimeout = configuration.languageServerShutdownTimeout
      var connections: [(ExternalLanguageServerConfiguration, LSPProcessConnection)] = []
      do {
        for server in preparedServers {
          let connection: LSPProcessConnection
          do {
            connection = try LSPProcessConnection(
              workspaceURL: configuration.workspaceURL,
              configuration: server.process,
              configurationProvider: server.configurationProvider
            )
          } catch {
            throw ExternalLanguageServerStartupError(
              serviceID: server.id,
              executable: server.process.executable,
              stage: .processLaunch,
              underlyingDescription: error.localizedDescription
            )
          }
          connections.append((server, connection))
          builder.addLanguageService(
            LanguageServiceRegistration(
              id: server.id,
              service: connection.service,
              role: server.role,
              priority: server.priority,
              selector: server.selector,
              shutdown: { try await connection.shutdown(timeout: shutdownTimeout) }
            )
          )
        }

        let backend = try await builder.build()
        for (server, connection) in connections {
          let task = Task { [weak backend] in
            for await line in connection.standardError {
              guard let backend, !Task.isCancelled else { return }
              backend.reportLanguageServerMessage(
                LanguageServerMessage(
                  kind: .log,
                  message: line,
                  serviceIdentifier: server.id.rawValue
                )
              )
            }
          }
          backend.retainLifetimeTask(task)

          let terminationTask = Task { [weak backend] in
            for await event in connection.terminationEvents {
              guard let backend, !Task.isCancelled, !event.expected else { return }
              backend.reportLanguageServerMessage(
                LanguageServerMessage(
                  kind: .error,
                  message:
                    "Language server process terminated unexpectedly "
                    + "(reason: \(event.reason.rawValue), status: \(event.status)).",
                  serviceIdentifier: server.id.rawValue
                )
              )
            }
          }
          backend.retainLifetimeTask(terminationTask)
        }
        do {
          for (server, connection) in connections {
            if server.automaticallyApplyWorkspaceEdits {
              await connection.service.setWorkspaceEditHandler(
                automaticWorkspaceEditHandler(for: backend)
              )
            }
            if server.eagerlyInitialize {
              do {
                _ = try await connection.service.initialize(
                  timeout: configuration.languageServerInitializationTimeout
                )
              } catch {
                if server.role == .supplemental {
                  try? await backend.languageServiceRouter?.unregister(server.id)
                  continue
                }
                throw ExternalLanguageServerStartupError(
                  serviceID: server.id,
                  executable: server.process.executable,
                  stage: .initialization,
                  underlyingDescription: error.localizedDescription
                )
              }
            }
          }
          return backend
        } catch {
          try? await backend.shutdown()
          throw error
        }
      } catch {
        for (_, connection) in connections { connection.terminate() }
        throw error
      }
    }
  }

  /// Ready-to-edit registrations for common language servers.
  ///
  /// These helpers do not install executables. Override `executable` or `arguments` when your local
  /// installation uses a wrapper script or custom launch command.
  public enum ExternalLanguageServerPresets {
    public static func swift(
      executable: String = "sourcekit-lsp",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "sourcekit-lsp",
        process: LanguageServerPresets.sourceKitLSP(executable: executable),
        selector: .init(languageIDs: ["swift"]),
        priority: priority
      )
    }

    public static func clangd(
      executable: String = "clangd",
      arguments: [String] = [],
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "clangd",
        process: LanguageServerPresets.clangd(executable: executable, arguments: arguments),
        selector: .init(languageIDs: ["c", "cpp", "objective-c", "objective-cpp"]),
        priority: priority
      )
    }

    public static func pyright(
      executable: String = "pyright-langserver",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "pyright",
        process: LanguageServerPresets.pyright(executable: executable),
        selector: .init(languageIDs: ["python"]),
        priority: priority
      )
    }

    public static func pythonLSP(
      executable: String = "pylsp",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "pylsp",
        process: LanguageServerPresets.pythonLSP(executable: executable),
        selector: .init(languageIDs: ["python"]),
        priority: priority
      )
    }

    public static func rustAnalyzer(
      executable: String = "rust-analyzer",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "rust-analyzer",
        process: LanguageServerPresets.rustAnalyzer(executable: executable),
        selector: .init(languageIDs: ["rust"]),
        role: .supplemental,
        priority: priority
      )
    }

    public static func gopls(
      executable: String = "gopls",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "gopls",
        process: LanguageServerPresets.gopls(executable: executable),
        selector: .init(languageIDs: ["go"]),
        priority: priority
      )
    }

    public static func typescript(
      executable: String = "typescript-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "typescript-language-server",
        process: LanguageServerPresets.typescript(executable: executable),
        selector: .init(languageIDs: [
          "javascript", "javascriptreact", "typescript", "typescriptreact",
        ]),
        priority: priority
      )
    }

    public static func java(
      executable: String = "jdtls",
      arguments: [String] = [],
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "jdtls",
        process: LanguageServerPresets.java(executable: executable, arguments: arguments),
        selector: .init(languageIDs: ["java"]),
        priority: priority
      )
    }

    public static func json(
      executable: String = "vscode-json-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "json-language-server",
        process: LanguageServerPresets.json(executable: executable),
        selector: .init(languageIDs: ["json", "jsonc"]),
        priority: priority
      )
    }

    public static func yaml(
      executable: String = "yaml-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "yaml-language-server",
        process: LanguageServerPresets.yaml(executable: executable),
        selector: .init(languageIDs: ["yaml"]),
        priority: priority
      )
    }

    public static func bash(
      executable: String = "bash-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "bash-language-server",
        process: LanguageServerPresets.bash(executable: executable),
        selector: .init(languageIDs: ["shellscript"]),
        priority: priority
      )
    }

    public static func ccls(
      executable: String = "ccls",
      arguments: [String] = [],
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "ccls",
        process: LanguageServerPresets.ccls(executable: executable, arguments: arguments),
        selector: .init(languageIDs: ["c", "cpp", "objective-c", "objective-cpp"]),
        priority: priority
      )
    }

    public static func eslint(
      executable: String = "vscode-eslint-language-server",
      priority: Int = 50
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "eslint-language-server",
        process: LanguageServerPresets.eslint(executable: executable),
        selector: .init(languageIDs: [
          "javascript", "javascriptreact", "typescript", "typescriptreact",
        ]),
        role: .supplemental,
        priority: priority
      )
    }

    public static func html(
      executable: String = "vscode-html-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "html-language-server",
        process: LanguageServerPresets.html(executable: executable),
        selector: .init(languageIDs: ["html"]),
        priority: priority
      )
    }

    public static func css(
      executable: String = "vscode-css-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "css-language-server",
        process: LanguageServerPresets.css(executable: executable),
        selector: .init(languageIDs: ["css", "scss", "less"]),
        priority: priority
      )
    }

    public static func lua(
      executable: String = "lua-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "lua-language-server",
        process: LanguageServerPresets.lua(executable: executable),
        selector: .init(languageIDs: ["lua"]),
        priority: priority
      )
    }

    public static func kotlin(
      executable: String = "kotlin-language-server",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "kotlin-language-server",
        process: LanguageServerPresets.kotlin(executable: executable),
        selector: .init(languageIDs: ["kotlin"]),
        priority: priority
      )
    }

    public static func ruby(
      executable: String = "solargraph",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "solargraph",
        process: LanguageServerPresets.solargraph(executable: executable),
        selector: .init(languageIDs: ["ruby"]),
        priority: priority
      )
    }

    public static func php(
      executable: String = "intelephense",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "intelephense",
        process: LanguageServerPresets.intelephense(executable: executable),
        selector: .init(languageIDs: ["php"]),
        priority: priority
      )
    }

    public static func csharp(
      executable: String = "OmniSharp",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "omnisharp",
        process: LanguageServerPresets.omniSharp(executable: executable),
        selector: .init(languageIDs: ["csharp"]),
        priority: priority
      )
    }

    public static func haskell(
      executable: String = "haskell-language-server-wrapper",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "haskell-language-server",
        process: LanguageServerPresets.haskell(executable: executable),
        selector: .init(languageIDs: ["haskell"]),
        priority: priority
      )
    }

    public static func ocaml(
      executable: String = "ocamllsp",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "ocamllsp",
        process: LanguageServerPresets.ocaml(executable: executable),
        selector: .init(languageIDs: ["ocaml"]),
        priority: priority
      )
    }

    public static func zig(
      executable: String = "zls",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "zls",
        process: LanguageServerPresets.zig(executable: executable),
        selector: .init(languageIDs: ["zig"]),
        priority: priority
      )
    }

    public static func terraform(
      executable: String = "terraform-ls",
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: "terraform-ls",
        process: LanguageServerPresets.terraform(executable: executable),
        selector: .init(languageIDs: ["terraform"]),
        priority: priority
      )
    }

    public static func custom(
      id: LanguageServiceID,
      executable: String,
      arguments: [String] = [],
      languageIDs: Set<String>,
      fileExtensions: Set<String> = [],
      initializationOptions: EditorJSONValue? = nil,
      priority: Int = 100
    ) -> ExternalLanguageServerConfiguration {
      .init(
        id: id,
        process: LanguageServerPresets.custom(
          executable: executable,
          arguments: arguments,
          initializationOptions: initializationOptions
        ),
        selector: .init(languageIDs: languageIDs, fileExtensions: fileExtensions),
        priority: priority
      )
    }
  }
#endif

/// Generic name for applications that are not Swift-specific.
public typealias MultiLanguageEditorBackend = SwiftEditorBackend
