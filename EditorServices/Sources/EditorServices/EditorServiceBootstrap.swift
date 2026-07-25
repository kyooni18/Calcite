import EditorCore
import EditorDAP
import EditorLSP
import EditorServiceKit
import EditorTreeSitter
import EditorWorkspace
import Foundation

/// A language supported by the high-level EditorServices bootstrap API.
public enum EditorLanguage: String, CaseIterable, Codable, Hashable, Sendable {
  case swift
  case c
  case cpp
  case objectiveC = "objective-c"
  case objectiveCPP = "objective-cpp"
  case python
  case rust
  case go
  case java
  case kotlin
  case javascript
  case typescript
  case html
  case css
  case json
  case yaml
  case shellscript
  case lua
  case ruby
  case php
  case csharp
  case fsharp
  case haskell
  case ocaml
  case scala
  case clojure
  case elixir
  case erlang
  case dart
  case nim
  case markdown
  case xml
  case sql
  case dockerfile
  case protobuf
  case graphql
  case vue
  case svelte
  case zig
  case terraform

  /// Languages commonly expected in a general-purpose source editor.
  public static let common: Set<Self> = [
    .swift, .c, .cpp, .objectiveC, .objectiveCPP, .python, .rust, .go,
    .java, .kotlin, .javascript, .typescript, .html, .css, .json, .yaml,
    .shellscript, .lua, .zig,
  ]

  /// Canonical LSP language IDs routed by this language entry.
  public var languageIDs: Set<String> {
    switch self {
    case .c, .cpp, .objectiveC, .objectiveCPP:
      return ["c", "cpp", "objective-c", "objective-cpp"]
    case .javascript, .typescript:
      return ["javascript", "javascriptreact", "typescript", "typescriptreact"]
    case .css:
      return ["css", "scss", "less"]
    case .json:
      return ["json", "jsonc"]
    default:
      return [rawValue]
    }
  }

  /// File extensions recognized by this language entry.
  public var fileExtensions: Set<String> {
    let ids = languageIDs
    return EditorLanguageCatalog.standard.definitions
      .filter { ids.contains($0.id) }
      .reduce(into: Set<String>()) { $0.formUnion($1.fileExtensions) }
  }
}

/// Controls which optional editor integrations are discovered and enabled.
public struct EditorFeatureSelection: Hashable, Codable, Sendable {
  public var languageServers: Bool
  public var syntax: Bool
  public var debugging: Bool

  public init(
    languageServers: Bool = true,
    syntax: Bool = true,
    debugging: Bool = true
  ) {
    self.languageServers = languageServers
    self.syntax = syntax
    self.debugging = debugging
  }

  public static let all = Self()
  public static let languageIntelligence = Self(debugging: false)
}

/// Determines whether missing optional services are tolerated.
public enum EditorServiceRequirementPolicy: String, Codable, Hashable, Sendable {
  /// Construct the backend with every service that is available and report the rest.
  case bestEffort
  /// Require an LSP for every requested language that has a known LSP profile.
  case requireLanguageServers
  /// Require every requested LSP and syntax grammar, plus a debug adapter when debugging is enabled.
  case strict
}

/// Explicit paths supplied by an application. Explicit values are authoritative and never silently replaced.
public struct EditorServiceOverrides: Sendable {
  public var languageServerExecutables: [EditorLanguage: String]
  /// Compatibility override used as the fallback LLDB adapter path.
  public var debugAdapterExecutable: String?
  public var debugAdapterExecutables: [EditorLanguage: String]
  public var debugAdapterArguments: [EditorLanguage: [String]]
  public var syntaxLibraries: [EditorLanguage: EditorSyntaxLibraryConfiguration]

  public init(
    languageServerExecutables: [EditorLanguage: String] = [:],
    debugAdapterExecutable: String? = nil,
    debugAdapterExecutables: [EditorLanguage: String] = [:],
    debugAdapterArguments: [EditorLanguage: [String]] = [:],
    syntaxLibraries: [EditorLanguage: EditorSyntaxLibraryConfiguration] = [:]
  ) {
    self.languageServerExecutables = languageServerExecutables
    self.debugAdapterExecutable = debugAdapterExecutable
    self.debugAdapterExecutables = debugAdapterExecutables
    self.debugAdapterArguments = debugAdapterArguments
    self.syntaxLibraries = syntaxLibraries
  }
}

/// A dynamically linked Tree-sitter grammar and optional query files.
public struct EditorSyntaxLibraryConfiguration: Hashable, Sendable {
  public var libraryURL: URL
  public var symbol: String?
  public var highlightsQueryURL: URL?
  public var foldsQueryURL: URL?
  public var priority: Int

  public init(
    libraryURL: URL,
    symbol: String? = nil,
    highlightsQueryURL: URL? = nil,
    foldsQueryURL: URL? = nil,
    priority: Int = 100
  ) {
    self.libraryURL = libraryURL
    self.symbol = symbol
    self.highlightsQueryURL = highlightsQueryURL
    self.foldsQueryURL = foldsQueryURL
    self.priority = priority
  }
}

/// High-level configuration for automatic multi-language backend construction.
public struct EditorServicesConfiguration: Sendable {
  public var workspaceURL: URL
  public var languageSelection: EditorLanguageSelection
  public var projectInspectionConfiguration: EditorProjectInspectionConfiguration
  public var features: EditorFeatureSelection
  public var requirementPolicy: EditorServiceRequirementPolicy
  public var overrides: EditorServiceOverrides
  public var environment: [String: String]
  public var languageCatalog: EditorLanguageCatalog
  public var completionStrategy: SwiftEditorCompletionStrategy
  public var completionLimit: Int
  public var sourceWorkspaceConfiguration: SourceWorkspaceConfiguration
  public var scanSourceWorkspaceOnConstruction: Bool
  public var sourceWorkspaceMonitoringInterval: Duration?
  public var languageServerInitializationTimeout: Duration?
  public var languageServerShutdownTimeout: Duration

  /// The explicitly selected languages. Assigning this property switches to manual mode.
  public var languages: Set<EditorLanguage> {
    get {
      switch languageSelection {
      case .automatic: return []
      case .automaticWithOverrides(let included, _): return included
      case .manual(let languages): return languages
      }
    }
    set { languageSelection = .manual(newValue) }
  }

  /// Creates the recommended configuration: inspect the opened project and start only needed services.
  public init(
    workspaceURL: URL,
    languageSelection: EditorLanguageSelection = .automatic,
    projectInspectionConfiguration: EditorProjectInspectionConfiguration = .init(),
    features: EditorFeatureSelection = .all,
    requirementPolicy: EditorServiceRequirementPolicy = .bestEffort,
    overrides: EditorServiceOverrides = .init(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    languageCatalog: EditorLanguageCatalog = .standard,
    completionStrategy: SwiftEditorCompletionStrategy = .languageServerOnly,
    completionLimit: Int = 100,
    sourceWorkspaceConfiguration: SourceWorkspaceConfiguration = .init(),
    scanSourceWorkspaceOnConstruction: Bool = true,
    sourceWorkspaceMonitoringInterval: Duration? = nil,
    languageServerInitializationTimeout: Duration? = .seconds(15),
    languageServerShutdownTimeout: Duration = .seconds(5)
  ) {
    self.workspaceURL = workspaceURL
    self.languageSelection = languageSelection
    self.projectInspectionConfiguration = projectInspectionConfiguration
    self.features = features
    self.requirementPolicy = requirementPolicy
    self.overrides = overrides
    self.environment = environment
    self.languageCatalog = languageCatalog
    self.completionStrategy = completionStrategy
    self.completionLimit = max(1, completionLimit)
    self.sourceWorkspaceConfiguration = sourceWorkspaceConfiguration
    self.scanSourceWorkspaceOnConstruction = scanSourceWorkspaceOnConstruction
    self.sourceWorkspaceMonitoringInterval = sourceWorkspaceMonitoringInterval
    self.languageServerInitializationTimeout = languageServerInitializationTimeout
    self.languageServerShutdownTimeout = languageServerShutdownTimeout
  }

  /// Manual-language compatibility initializer. Automatic project inspection is disabled.
  public init(
    workspaceURL: URL,
    languages: Set<EditorLanguage>,
    features: EditorFeatureSelection = .all,
    requirementPolicy: EditorServiceRequirementPolicy = .bestEffort,
    overrides: EditorServiceOverrides = .init(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    languageCatalog: EditorLanguageCatalog = .standard,
    completionStrategy: SwiftEditorCompletionStrategy = .languageServerOnly,
    completionLimit: Int = 100,
    sourceWorkspaceConfiguration: SourceWorkspaceConfiguration = .init(),
    scanSourceWorkspaceOnConstruction: Bool = true,
    sourceWorkspaceMonitoringInterval: Duration? = nil,
    languageServerInitializationTimeout: Duration? = .seconds(15),
    languageServerShutdownTimeout: Duration = .seconds(5)
  ) {
    self.init(
      workspaceURL: workspaceURL,
      languageSelection: .manual(languages),
      features: features,
      requirementPolicy: requirementPolicy,
      overrides: overrides,
      environment: environment,
      languageCatalog: languageCatalog,
      completionStrategy: completionStrategy,
      completionLimit: completionLimit,
      sourceWorkspaceConfiguration: sourceWorkspaceConfiguration,
      scanSourceWorkspaceOnConstruction: scanSourceWorkspaceOnConstruction,
      sourceWorkspaceMonitoringInterval: sourceWorkspaceMonitoringInterval,
      languageServerInitializationTimeout: languageServerInitializationTimeout,
      languageServerShutdownTimeout: languageServerShutdownTimeout
    )
  }
}

/// A resolved Debug Adapter Protocol launcher for one or more project languages.
public struct EditorDebugAdapterConfiguration: Hashable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var executable: String
  public var arguments: [String]
  public var languages: Set<EditorLanguage>

  public init(
    id: String,
    displayName: String,
    executable: String,
    arguments: [String] = [],
    languages: Set<EditorLanguage>
  ) {
    self.id = id
    self.displayName = displayName
    self.executable = executable
    self.arguments = arguments
    self.languages = languages
  }
}

public enum EditorServiceFeature: String, Codable, Hashable, Sendable {
  case languageServer
  case syntax
  case debugAdapter
}

public enum EditorServiceAvailability: Hashable, Codable, Sendable {
  case available(path: String?)
  case missing
  case disabled
  case unsupported(reason: String)
  case invalid(reason: String)

  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }
}

/// One actionable discovery result for an LSP, parser, or debug adapter.
public struct EditorServiceDiagnostic: Hashable, Codable, Sendable, Identifiable {
  public var id: String
  public var feature: EditorServiceFeature
  public var language: EditorLanguage?
  public var serviceName: String
  public var availability: EditorServiceAvailability
  public var attemptedLocations: [String]
  public var recoverySuggestion: String?
  public var required: Bool

  public init(
    id: String,
    feature: EditorServiceFeature,
    language: EditorLanguage? = nil,
    serviceName: String,
    availability: EditorServiceAvailability,
    attemptedLocations: [String] = [],
    recoverySuggestion: String? = nil,
    required: Bool = false
  ) {
    self.id = id
    self.feature = feature
    self.language = language
    self.serviceName = serviceName
    self.availability = availability
    self.attemptedLocations = attemptedLocations
    self.recoverySuggestion = recoverySuggestion
    self.required = required
  }
}

/// Complete, serializable service availability report.
public struct EditorServiceAvailabilityReport: Hashable, Codable, Sendable {
  public var diagnostics: [EditorServiceDiagnostic]

  public init(diagnostics: [EditorServiceDiagnostic] = []) {
    self.diagnostics = diagnostics
  }

  public var available: [EditorServiceDiagnostic] {
    diagnostics.filter { $0.availability.isAvailable }
  }

  public var unavailable: [EditorServiceDiagnostic] {
    diagnostics.filter { !$0.availability.isAvailable && $0.availability != .disabled }
  }

  public var missingRequired: [EditorServiceDiagnostic] {
    diagnostics.filter { $0.required && !$0.availability.isAvailable }
  }

  public func diagnostics(
    for language: EditorLanguage,
    feature: EditorServiceFeature? = nil
  ) -> [EditorServiceDiagnostic] {
    diagnostics.filter { value in
      value.language == language && (feature == nil || value.feature == feature)
    }
  }
}

public enum EditorServiceBootstrapError: Error, Sendable {
  case projectInspectionFailed(String)
  case requiredServicesUnavailable(EditorServiceAvailabilityReport)
  case languageServerStartupFailed(
    report: EditorServiceAvailabilityReport,
    error: ExternalLanguageServerStartupError
  )
  case backendInitializationFailed(
    report: EditorServiceAvailabilityReport,
    underlyingDescription: String
  )
}

extension EditorServiceBootstrapError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .projectInspectionFailed(let description):
      return "The opened project could not be inspected: \(description)"
    case .requiredServicesUnavailable(let report):
      let names = report.missingRequired.map(\.serviceName).joined(separator: ", ")
      return "Required editor services are unavailable: \(names)."
    case .languageServerStartupFailed(_, let error):
      return error.errorDescription
    case .backendInitializationFailed(_, let description):
      return "The editor backend could not be initialized: \(description)"
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .projectInspectionFailed:
      return
        "Check that the project directory exists and is readable, or use manual language selection."
    case .requiredServicesUnavailable(let report):
      let suggestions = report.missingRequired.compactMap(\.recoverySuggestion)
      return suggestions.isEmpty ? nil : suggestions.joined(separator: " ")
    case .languageServerStartupFailed(_, let error):
      return error.recoverySuggestion
    case .backendInitializationFailed:
      return "Inspect the attached availability report and the underlying service error."
    }
  }
}

/// A process-free inspection result suitable for settings and preflight user interfaces.
public struct EditorServiceInspectionResult: Sendable {
  public let workspaceURL: URL
  public let selectedLanguages: Set<EditorLanguage>
  public let projectInspection: EditorProjectInspectionReport?
  public let report: EditorServiceAvailabilityReport
  public let debugAdapters: [EditorDebugAdapterConfiguration]
  public let debuggerPath: String?

  public init(
    workspaceURL: URL,
    selectedLanguages: Set<EditorLanguage>,
    projectInspection: EditorProjectInspectionReport?,
    report: EditorServiceAvailabilityReport,
    debugAdapters: [EditorDebugAdapterConfiguration] = [],
    debuggerPath: String?
  ) {
    self.workspaceURL = workspaceURL
    self.selectedLanguages = selectedLanguages
    self.projectInspection = projectInspection
    self.report = report
    self.debugAdapters = debugAdapters
    self.debuggerPath = debuggerPath
  }

  public func debugAdapter(for language: EditorLanguage) -> EditorDebugAdapterConfiguration? {
    debugAdapters.first { $0.languages.contains(language) }
  }
}

/// Result returned by the high-level bootstrap API.
public struct EditorServiceBootstrapResult: Sendable {
  public let backend: MultiLanguageEditorBackend
  public let selectedLanguages: Set<EditorLanguage>
  public let projectInspection: EditorProjectInspectionReport?
  public let report: EditorServiceAvailabilityReport
  public let debugAdapters: [EditorDebugAdapterConfiguration]
  public let debuggerPath: String?

  public init(
    backend: MultiLanguageEditorBackend,
    selectedLanguages: Set<EditorLanguage>,
    projectInspection: EditorProjectInspectionReport?,
    report: EditorServiceAvailabilityReport,
    debugAdapters: [EditorDebugAdapterConfiguration] = [],
    debuggerPath: String?
  ) {
    self.backend = backend
    self.selectedLanguages = selectedLanguages
    self.projectInspection = projectInspection
    self.report = report
    self.debugAdapters = debugAdapters
    self.debuggerPath = debuggerPath
  }

  public func debugAdapter(for language: EditorLanguage) -> EditorDebugAdapterConfiguration? {
    debugAdapters.first { $0.languages.contains(language) }
  }

  /// Compatibility initializer retained for applications constructing the result directly.
  public init(
    backend: MultiLanguageEditorBackend,
    report: EditorServiceAvailabilityReport,
    debuggerPath: String?
  ) {
    self.init(
      backend: backend,
      selectedLanguages: [],
      projectInspection: nil,
      report: report,
      debugAdapters: [],
      debuggerPath: debuggerPath
    )
  }

  /// Compatibility summary for applications that previously used string dictionaries.
  public var detectedServices: [String: String] {
    var values: [String: String] = [:]
    for diagnostic in report.available {
      guard case .available(let path?) = diagnostic.availability else { continue }
      values[diagnostic.serviceName] = path
    }
    return values
  }

  public var missingServices: [String] {
    Array(Set(report.unavailable.map(\.serviceName))).sorted()
  }
}

#if os(macOS) || os(Linux)
  /// Automatic discovery and construction for a multi-language editor backend.
  public enum EditorServiceBootstrap {
    /// Recommended automatic entry point. The opened project is inspected before services are selected.
    public static func initialize(
      workspaceURL: URL,
      requirementPolicy: EditorServiceRequirementPolicy = .bestEffort,
      overrides: EditorServiceOverrides = .init(),
      sourceWorkspaceMonitoringInterval: Duration? = .seconds(1)
    ) async throws -> EditorServiceBootstrapResult {
      try await initialize(
        configuration: .init(
          workspaceURL: workspaceURL,
          languageSelection: .automatic,
          requirementPolicy: requirementPolicy,
          overrides: overrides,
          sourceWorkspaceMonitoringInterval: sourceWorkspaceMonitoringInterval
        )
      )
    }

    /// Manual compatibility entry point. Only the supplied languages are enabled.
    public static func initialize(
      workspaceURL: URL,
      languages: Set<EditorLanguage>,
      requirementPolicy: EditorServiceRequirementPolicy = .bestEffort,
      overrides: EditorServiceOverrides = .init(),
      sourceWorkspaceMonitoringInterval: Duration? = .seconds(1)
    ) async throws -> EditorServiceBootstrapResult {
      try await initialize(
        configuration: .init(
          workspaceURL: workspaceURL,
          languages: languages,
          requirementPolicy: requirementPolicy,
          overrides: overrides,
          sourceWorkspaceMonitoringInterval: sourceWorkspaceMonitoringInterval
        )
      )
    }

    /// Inspects project languages and service availability without launching an LSP or DAP process.
    public static func inspect(
      workspaceURL: URL,
      languageSelection: EditorLanguageSelection = .automatic,
      requirementPolicy: EditorServiceRequirementPolicy = .bestEffort,
      overrides: EditorServiceOverrides = .init()
    ) async throws -> EditorServiceInspectionResult {
      try await inspect(
        configuration: .init(
          workspaceURL: workspaceURL,
          languageSelection: languageSelection,
          requirementPolicy: requirementPolicy,
          overrides: overrides,
          scanSourceWorkspaceOnConstruction: false
        )
      )
    }

    /// Inspects project languages and service availability without launching an LSP or DAP process.
    public static func inspect(
      configuration: EditorServicesConfiguration
    ) async throws -> EditorServiceInspectionResult {
      let prepared = try await prepare(configuration: configuration)
      return .init(
        workspaceURL: configuration.workspaceURL,
        selectedLanguages: prepared.languages,
        projectInspection: prepared.projectInspection,
        report: prepared.report,
        debugAdapters: prepared.debugAdapters,
        debuggerPath: prepared.debuggerPath
      )
    }

    public static func initialize(
      configuration: EditorServicesConfiguration
    ) async throws -> EditorServiceBootstrapResult {
      let prepared = try await prepare(configuration: configuration)
      guard prepared.report.missingRequired.isEmpty else {
        throw EditorServiceBootstrapError.requiredServicesUnavailable(prepared.report)
      }

      do {
        let backend = try await MultiLanguageEditorBackend.makeMultiLanguage(
          configuration: .init(
            workspaceURL: configuration.workspaceURL,
            languageCatalog: configuration.languageCatalog,
            languageServers: prepared.servers,
            treeSitterRegistry: prepared.registry,
            enableLexicalSyntaxFallback: configuration.features.syntax,
            completionStrategy: configuration.completionStrategy,
            completionLimit: configuration.completionLimit,
            sourceWorkspaceConfiguration: configuration.sourceWorkspaceConfiguration,
            processEnvironment: configuration.environment,
            scanSourceWorkspaceOnConstruction: configuration.scanSourceWorkspaceOnConstruction,
            sourceWorkspaceMonitoringInterval: configuration.sourceWorkspaceMonitoringInterval,
            languageServerInitializationTimeout: configuration.languageServerInitializationTimeout,
            languageServerShutdownTimeout: configuration.languageServerShutdownTimeout
          )
        )
        return .init(
          backend: backend,
          selectedLanguages: prepared.languages,
          projectInspection: prepared.projectInspection,
          report: prepared.report,
          debugAdapters: prepared.debugAdapters,
          debuggerPath: prepared.debuggerPath
        )
      } catch let error as ExternalLanguageServerStartupError {
        throw EditorServiceBootstrapError.languageServerStartupFailed(
          report: prepared.report,
          error: error
        )
      } catch {
        throw EditorServiceBootstrapError.backendInitializationFailed(
          report: prepared.report,
          underlyingDescription: String(describing: error)
        )
      }
    }

    private struct PreparedServices {
      var languages: Set<EditorLanguage>
      var projectInspection: EditorProjectInspectionReport?
      var report: EditorServiceAvailabilityReport
      var servers: [ExternalLanguageServerConfiguration]
      var registry: TreeSitterLanguageRegistry
      var debugAdapters: [EditorDebugAdapterConfiguration]
      var debuggerPath: String?
    }

    private static func prepare(
      configuration: EditorServicesConfiguration
    ) async throws -> PreparedServices {
      let selection: (languages: Set<EditorLanguage>, report: EditorProjectInspectionReport?)
      do {
        selection = try await resolveLanguages(configuration: configuration)
      } catch {
        throw EditorServiceBootstrapError.projectInspectionFailed(error.localizedDescription)
      }

      var diagnostics: [EditorServiceDiagnostic] = []
      var servers: [ExternalLanguageServerConfiguration] = []
      var registeredServerIDs = Set<String>()
      var languageServerResolutions: [String: EditorExecutableResolution] = [:]
      let registry = try TreeSitterLanguageRegistry()
      let sortedLanguages = selection.languages.sorted(by: { $0.rawValue < $1.rawValue })

      for language in sortedLanguages {
        let profile = EditorLanguage.profile(for: language)

        if configuration.features.languageServers {
          if let reason = languageServerSkipReason(
            language: language,
            profile: profile,
            configuration: configuration,
            projectInspection: selection.report
          ) {
            diagnostics.append(
              .init(
                id: "lsp:\(profile.serverID):\(language.rawValue)",
                feature: .languageServer,
                language: language,
                serviceName: profile.displayName,
                availability: .disabled,
                recoverySuggestion: reason,
                required: false
              )
            )
          } else {
            let required = configuration.requirementPolicy != .bestEffort
            let resolution: EditorExecutableResolution
            if let cached = languageServerResolutions[profile.serverID] {
              resolution = cached
            } else {
              let explicitPath = sharedLanguageServerOverride(
                for: language,
                profile: profile,
                languages: sortedLanguages,
                overrides: configuration.overrides.languageServerExecutables
              )
              resolution = EditorExecutableDiscovery.resolve(
                explicitPath: explicitPath,
                environmentKeys: profile.environmentKeys,
                executableNames: profile.executableNames,
                extraPaths: profile.extraExecutablePaths,
                environment: configuration.environment,
                useXcrun: profile.useXcrun,
                workspaceURL: configuration.workspaceURL
              )
              languageServerResolutions[profile.serverID] = resolution
            }
            diagnostics.append(
              resolution.diagnostic(
                id: "lsp:\(profile.serverID)",
                feature: .languageServer,
                language: language,
                serviceName: profile.displayName,
                recoverySuggestion: profile.installSuggestion,
                required: required
              )
            )
            if let path = resolution.path, registeredServerIDs.insert(profile.serverID).inserted {
              var server = profile.makeServer(path)
              if configuration.requirementPolicy == .bestEffort {
                server.role = .supplemental
              }
              servers.append(server)
            }
          }
        } else {
          diagnostics.append(
            .init(
              id: "lsp:\(profile.serverID):\(language.rawValue)",
              feature: .languageServer,
              language: language,
              serviceName: profile.displayName,
              availability: .disabled
            )
          )
        }

        if configuration.features.syntax {
          let syntaxRequired = configuration.requirementPolicy == .strict
          diagnostics.append(
            try registerSyntax(
              language: language,
              profile: profile,
              override: configuration.overrides.syntaxLibraries[language],
              environment: configuration.environment,
              registry: registry,
              required: syntaxRequired
            )
          )
        } else {
          diagnostics.append(
            .init(
              id: "syntax:\(language.rawValue)",
              feature: .syntax,
              language: language,
              serviceName: "Tree-sitter \(language.rawValue)",
              availability: .disabled
            )
          )
        }
      }

      let debugResult = inspectDebugAdapters(
        languages: selection.languages,
        configuration: configuration
      )
      diagnostics.append(contentsOf: debugResult.diagnostics)

      return .init(
        languages: selection.languages,
        projectInspection: selection.report,
        report: .init(diagnostics: diagnostics),
        servers: servers,
        registry: registry,
        debugAdapters: debugResult.adapters,
        debuggerPath: debugResult.adapters.first(where: { $0.id == "lldb-dap" })?.executable
      )
    }

    private static func languageServerSkipReason(
      language: EditorLanguage,
      profile: EditorLanguage.Profile,
      configuration: EditorServicesConfiguration,
      projectInspection: EditorProjectInspectionReport?
    ) -> String? {
      guard !profile.requiredProjectMarkers.isEmpty else { return nil }

      if configuration.overrides.languageServerExecutables[language] != nil {
        return nil
      }

      switch configuration.languageSelection {
      case .manual:
        return nil
      case .automaticWithOverrides(let included, _):
        if included.contains(language) { return nil }
      case .automatic:
        break
      }

      let detectedMarkers = projectInspection?.evidence(for: language)?.projectMarkers ?? []
      guard detectedMarkers.isDisjoint(with: profile.requiredProjectMarkers) else { return nil }

      let markers = profile.requiredProjectMarkers.sorted().joined(separator: " or ")
      return
        "\(profile.displayName) was not started because the opened folder is not a recognized \(language.displayName) workspace. Add \(markers), open the actual project root, or explicitly enable/configure the server in Advanced Settings. Built-in syntax highlighting and project-local completion remain available."
    }

    private static func resolveLanguages(
      configuration: EditorServicesConfiguration
    ) async throws -> (languages: Set<EditorLanguage>, report: EditorProjectInspectionReport?) {
      switch configuration.languageSelection {
      case .manual(let languages):
        return (languages, nil)
      case .automatic:
        let report = try await EditorProjectInspector.inspect(
          workspaceURL: configuration.workspaceURL,
          languageCatalog: configuration.languageCatalog,
          configuration: configuration.projectInspectionConfiguration
        )
        return (report.languages, report)
      case .automaticWithOverrides(let included, let excluded):
        let report = try await EditorProjectInspector.inspect(
          workspaceURL: configuration.workspaceURL,
          languageCatalog: configuration.languageCatalog,
          configuration: configuration.projectInspectionConfiguration
        )
        return (report.languages.union(included).subtracting(excluded), report)
      }
    }

    private struct DebugInspection {
      var diagnostics: [EditorServiceDiagnostic]
      var adapters: [EditorDebugAdapterConfiguration]
    }

    private static func inspectDebugAdapters(
      languages: Set<EditorLanguage>,
      configuration: EditorServicesConfiguration
    ) -> DebugInspection {
      let sorted = languages.sorted { $0.rawValue < $1.rawValue }
      guard configuration.features.debugging else {
        return .init(
          diagnostics: sorted.map { language in
            .init(
              id: "dap:\(language.rawValue)",
              feature: .debugAdapter,
              language: language,
              serviceName: "Debug adapter",
              availability: .disabled
            )
          },
          adapters: []
        )
      }

      let required = configuration.requirementPolicy == .strict
      let grouped = Dictionary(
        grouping: sorted.compactMap { language in
          DebugAdapterProfile.profile(for: language).map { (language, $0) }
        }, by: { $0.1.id })
      var diagnostics: [EditorServiceDiagnostic] = []
      var adapters: [EditorDebugAdapterConfiguration] = []

      let supportedLanguages = Set(grouped.values.flatMap { $0.map(\.0) })
      for language in sorted where !supportedLanguages.contains(language) {
        diagnostics.append(
          .init(
            id: "dap:unsupported:\(language.rawValue)",
            feature: .debugAdapter,
            language: language,
            serviceName: "Debug adapter for \(language.rawValue)",
            availability: .unsupported(
              reason:
                "No default DAP launcher is known for this language. Configure one in the application-specific debug interface."
            ),
            recoverySuggestion:
              "Provide a custom debug-adapter integration for \(language.rawValue).",
            required: required
          )
        )
      }

      for entries in grouped.values.sorted(by: { $0[0].1.id < $1[0].1.id }) {
        let profile = entries[0].1
        let profileLanguages = Set(entries.map(\.0))
        let explicit =
          profileLanguages.sorted(by: { $0.rawValue < $1.rawValue }).lazy
          .compactMap { configuration.overrides.debugAdapterExecutables[$0] }.first
          ?? (profile.id == "lldb-dap" ? configuration.overrides.debugAdapterExecutable : nil)
        let resolution = EditorExecutableDiscovery.resolve(
          explicitPath: explicit,
          environmentKeys: profile.environmentKeys,
          executableNames: profile.executableNames,
          extraPaths: profile.extraExecutablePaths,
          environment: configuration.environment,
          useXcrun: profile.useXcrun,
          workspaceURL: configuration.workspaceURL
        )
        let customArguments = profileLanguages.sorted(by: { $0.rawValue < $1.rawValue }).lazy
          .compactMap { configuration.overrides.debugAdapterArguments[$0] }.first
        if let path = resolution.path {
          adapters.append(
            .init(
              id: profile.id,
              displayName: profile.displayName,
              executable: path,
              arguments: customArguments ?? profile.arguments,
              languages: profileLanguages
            )
          )
        }
        for language in profileLanguages.sorted(by: { $0.rawValue < $1.rawValue }) {
          diagnostics.append(
            resolution.diagnostic(
              id: "dap:\(profile.id)",
              feature: .debugAdapter,
              language: language,
              serviceName: profile.displayName,
              recoverySuggestion: profile.installSuggestion,
              required: required
            )
          )
        }
      }

      return .init(
        diagnostics: diagnostics.sorted { $0.id < $1.id },
        adapters: adapters.sorted { $0.id < $1.id }
      )
    }

    private struct DebugAdapterProfile {
      var id: String
      var displayName: String
      var executableNames: [String]
      var environmentKeys: [String]
      var extraExecutablePaths: [String]
      var arguments: [String]
      var useXcrun: Bool
      var installSuggestion: String

      static func profile(for language: EditorLanguage) -> Self? {
        switch language {
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP, .rust, .zig:
          return .init(
            id: "lldb-dap",
            displayName: "LLDB DAP",
            executableNames: ["lldb-dap", "codelldb"],
            environmentKeys: ["LLDB_DAP_PATH", "LLDB_DAP", "CODELLDB_PATH"],
            extraExecutablePaths: [
              "/usr/local/swift/usr/bin/lldb-dap", "/usr/bin/lldb-dap",
              "/opt/homebrew/bin/lldb-dap", "/usr/local/bin/lldb-dap",
              FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vscode/extensions/vadimcn.vscode-lldb/adapter/codelldb")
                .path,
            ],
            arguments: [],
            useXcrun: true,
            installSuggestion:
              "Install lldb-dap with Swift/LLVM, or configure CodeLLDB's codelldb executable."
          )
        case .go:
          return .init(
            id: "delve", displayName: "Delve DAP", executableNames: ["dlv"],
            environmentKeys: ["DLV_PATH", "DELVE_PATH"], extraExecutablePaths: [],
            arguments: ["dap"], useXcrun: false,
            installSuggestion:
              "Install Delve with `go install github.com/go-delve/delve/cmd/dlv@latest`."
          )
        case .python:
          return .init(
            id: "debugpy", displayName: "debugpy Adapter",
            executableNames: ["debugpy-adapter"], environmentKeys: ["DEBUGPY_ADAPTER_PATH"],
            extraExecutablePaths: [], arguments: [], useXcrun: false,
            installSuggestion: "Install debugpy and expose debugpy-adapter on PATH."
          )
        case .csharp, .fsharp:
          return .init(
            id: "netcoredbg", displayName: "NetCoreDbg", executableNames: ["netcoredbg"],
            environmentKeys: ["NETCOREDBG_PATH"], extraExecutablePaths: [],
            arguments: ["--interpreter=vscode"], useXcrun: false,
            installSuggestion: "Install NetCoreDbg and expose netcoredbg on PATH."
          )
        case .dart:
          return .init(
            id: "dart-debug-adapter", displayName: "Dart Debug Adapter",
            executableNames: ["dart"], environmentKeys: ["DART_PATH"],
            extraExecutablePaths: [], arguments: ["debug_adapter"], useXcrun: false,
            installSuggestion: "Install the Dart SDK and expose dart on PATH."
          )
        default:
          return nil
        }
      }
    }

    private static func sharedLanguageServerOverride(
      for language: EditorLanguage,
      profile: EditorLanguage.Profile,
      languages: [EditorLanguage],
      overrides: [EditorLanguage: String]
    ) -> String? {
      if let direct = overrides[language] { return direct }
      return languages.lazy.compactMap { candidate -> String? in
        guard EditorLanguage.profile(for: candidate).serverID == profile.serverID else {
          return nil
        }
        return overrides[candidate]
      }.first
    }

    private static func registerSyntax(
      language: EditorLanguage,
      profile: EditorLanguage.Profile,
      override: EditorSyntaxLibraryConfiguration?,
      environment: [String: String],
      registry: TreeSitterLanguageRegistry,
      required: Bool
    ) throws -> EditorServiceDiagnostic {
      if language == .swift {
        do {
          try registry.register(try TreeSitterLanguageRegistry.swiftRegistration(priority: 100))
          return .init(
            id: "syntax:swift",
            feature: .syntax,
            language: .swift,
            serviceName: "Tree-sitter Swift",
            availability: .available(path: "bundled"),
            required: required
          )
        } catch {
          return .init(
            id: "syntax:swift",
            feature: .syntax,
            language: .swift,
            serviceName: "Tree-sitter Swift",
            availability: .invalid(reason: String(describing: error)),
            recoverySuggestion: "Verify the bundled TreeSitterSwift package and query resources.",
            required: required
          )
        }
      }

      let configured: EditorSyntaxLibraryConfiguration?
      let attempted: [String]
      if let override {
        configured = override
        attempted = [override.libraryURL.path]
      } else {
        let resolution = EditorSyntaxLibraryDiscovery.resolve(
          language: language,
          profile: profile,
          environment: environment
        )
        configured = resolution.configuration
        attempted = resolution.attempted
      }

      guard let configured else {
        return .init(
          id: "syntax:\(language.rawValue)",
          feature: .syntax,
          language: language,
          serviceName: "Syntax \(language.rawValue)",
          availability: .available(path: "built-in lexical fallback"),
          attemptedLocations: attempted,
          recoverySuggestion:
            "Lexical highlighting is active. Provide EditorSyntaxLibraryConfiguration or set \(profile.syntaxEnvironmentKey) for structural Tree-sitter highlighting and folding.",
          required: required
        )
      }

      do {
        let dynamic = try DynamicTreeSitterLanguage(
          libraryURL: configured.libraryURL,
          symbol: configured.symbol ?? profile.syntaxSymbol
        )
        let queries = try TreeSitterQuerySet.load(
          highlightsURL: configured.highlightsQueryURL,
          foldsURL: configured.foldsQueryURL
        )
        try registry.register(
          dynamic.registration(
            id: "tree-sitter-\(language.rawValue)",
            languageIDs: profile.languageIDs,
            fileExtensions: profile.fileExtensions,
            priority: configured.priority,
            queries: queries
          ))
        return .init(
          id: "syntax:\(language.rawValue)",
          feature: .syntax,
          language: language,
          serviceName: "Tree-sitter \(language.rawValue)",
          availability: .available(path: configured.libraryURL.path),
          attemptedLocations: attempted,
          required: required
        )
      } catch {
        return .init(
          id: "syntax:\(language.rawValue)",
          feature: .syntax,
          language: language,
          serviceName: "Syntax \(language.rawValue)",
          availability: .available(path: "built-in lexical fallback"),
          attemptedLocations: attempted,
          recoverySuggestion:
            "The configured Tree-sitter grammar could not load (\(error.localizedDescription)). Lexical highlighting remains active; check the library architecture, exported symbol \(configured.symbol ?? profile.syntaxSymbol), and query files.",
          required: required
        )
      }
    }
  }

  /// Short namespace for the simplest public construction API.
  public enum EditorServicesBootstrap {
    /// Inspects the opened project and builds only the services it needs.
    public static func make(
      workspaceURL: URL,
      policy: EditorServiceRequirementPolicy = .bestEffort
    ) async throws -> EditorServiceBootstrapResult {
      try await EditorServiceBootstrap.initialize(
        workspaceURL: workspaceURL,
        requirementPolicy: policy
      )
    }

    /// Builds a backend for an explicit manual language set.
    public static func make(
      workspaceURL: URL,
      languages: Set<EditorLanguage>,
      policy: EditorServiceRequirementPolicy = .bestEffort
    ) async throws -> EditorServiceBootstrapResult {
      try await EditorServiceBootstrap.initialize(
        workspaceURL: workspaceURL,
        languages: languages,
        requirementPolicy: policy
      )
    }

    /// Performs automatic project and service discovery without starting external processes.
    public static func inspect(
      workspaceURL: URL,
      languageSelection: EditorLanguageSelection = .automatic,
      policy: EditorServiceRequirementPolicy = .bestEffort,
      overrides: EditorServiceOverrides = .init()
    ) async throws -> EditorServiceInspectionResult {
      try await EditorServiceBootstrap.inspect(
        workspaceURL: workspaceURL,
        languageSelection: languageSelection,
        requirementPolicy: policy,
        overrides: overrides
      )
    }

    /// Compatibility spelling retained for existing integrations.
    public static func makeBackend(
      workspaceURL: URL,
      policy: EditorServiceRequirementPolicy = .bestEffort
    ) async throws -> EditorServiceBootstrapResult {
      try await make(workspaceURL: workspaceURL, policy: policy)
    }

    /// Manual compatibility spelling retained for existing integrations.
    public static func makeBackend(
      workspaceURL: URL,
      languages: Set<EditorLanguage>,
      policy: EditorServiceRequirementPolicy = .bestEffort
    ) async throws -> EditorServiceBootstrapResult {
      try await make(workspaceURL: workspaceURL, languages: languages, policy: policy)
    }
  }

  private struct EditorExecutableResolution {
    var path: String?
    var attempted: [String]
    var invalidReason: String?

    func diagnostic(
      id: String,
      feature: EditorServiceFeature,
      language: EditorLanguage? = nil,
      serviceName: String,
      recoverySuggestion: String?,
      required: Bool
    ) -> EditorServiceDiagnostic {
      let availability: EditorServiceAvailability
      if let path {
        availability = .available(path: path)
      } else if let invalidReason {
        availability = .invalid(reason: invalidReason)
      } else {
        availability = .missing
      }
      return .init(
        id: language.map { "\(id):\($0.rawValue)" } ?? id,
        feature: feature,
        language: language,
        serviceName: serviceName,
        availability: availability,
        attemptedLocations: attempted,
        recoverySuggestion: recoverySuggestion,
        required: required
      )
    }
  }

  private enum EditorExecutableDiscovery {
    static func resolve(
      explicitPath: String?,
      environmentKeys: [String],
      executableNames: [String],
      extraPaths: [String],
      environment: [String: String],
      useXcrun: Bool,
      workspaceURL: URL? = nil
    ) -> EditorExecutableResolution {
      let effectiveEnvironment = EditorProcessEnvironment.prepared(
        base: environment,
        workingDirectory: workspaceURL
      )
      if let explicitPath {
        return authoritative(explicitPath)
      }
      for key in environmentKeys {
        if let value = effectiveEnvironment[key],
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return authoritative(value)
        }
      }

      var candidates: [String] = []
      if let workspaceURL {
        let projectDirectories = [
          workspaceURL.appendingPathComponent("node_modules/.bin", isDirectory: true),
          workspaceURL.appendingPathComponent(".venv/bin", isDirectory: true),
          workspaceURL.appendingPathComponent("venv/bin", isDirectory: true),
          workspaceURL.appendingPathComponent(".tools/bin", isDirectory: true),
          workspaceURL.appendingPathComponent("bin", isDirectory: true),
        ]
        for directory in projectDirectories {
          for name in executableNames {
            candidates.append(directory.appendingPathComponent(name).path)
          }
        }
      }
      for directory in (effectiveEnvironment["PATH"] ?? "").split(separator: ":") {
        for name in executableNames {
          candidates.append(
            URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path)
        }
      }
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      let common = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "\(home)/.local/bin", "\(home)/bin", "\(home)/.cargo/bin",
        "\(home)/go/bin",
      ]
      for directory in common {
        for name in executableNames {
          candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(name).path)
        }
      }
      candidates.append(
        contentsOf: extensionDebugAdapterCandidates(
          executableNames: executableNames,
          homeDirectory: URL(fileURLWithPath: home, isDirectory: true)
        ))
      candidates.append(contentsOf: extraPaths)

      #if os(macOS)
        if useXcrun {
          for name in executableNames {
            if let path = commandOutput("/usr/bin/xcrun", ["--find", name]) {
              candidates.insert(path, at: 0)
            }
          }
        }
      #endif

      var attempted: [String] = []
      for candidate in candidates {
        let path = NSString(string: candidate).expandingTildeInPath
        guard !attempted.contains(path) else { continue }
        attempted.append(path)
        if FileManager.default.isExecutableFile(atPath: path) {
          return .init(
            path: URL(fileURLWithPath: path).standardizedFileURL.path, attempted: attempted)
        }
      }
      return .init(path: nil, attempted: attempted)
    }

    private static func extensionDebugAdapterCandidates(
      executableNames: [String],
      homeDirectory: URL
    ) -> [String] {
      guard executableNames.contains("codelldb") else { return [] }
      let roots = [
        homeDirectory.appendingPathComponent(".vscode/extensions", isDirectory: true),
        homeDirectory.appendingPathComponent(".vscode-insiders/extensions", isDirectory: true),
        homeDirectory.appendingPathComponent(".cursor/extensions", isDirectory: true),
        homeDirectory.appendingPathComponent(".windsurf/extensions", isDirectory: true),
        homeDirectory.appendingPathComponent(".trae/extensions", isDirectory: true),
      ]
      var values: [(URL, Date)] = []
      let fileManager = FileManager.default
      for root in roots {
        let extensions =
          (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
          )) ?? []
        for extensionURL in extensions
        where extensionURL.lastPathComponent.lowercased().hasPrefix("vadimcn.vscode-lldb-") {
          for relativePath in ["adapter/codelldb", "extension/adapter/codelldb"] {
            let candidate = extensionURL.appendingPathComponent(relativePath)
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            let date =
              (try? extensionURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            values.append((candidate, date))
          }
        }
      }
      return values.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.path > rhs.0.path
      }.map { $0.0.path }
    }

    private static func authoritative(_ value: String) -> EditorExecutableResolution {
      let path = NSString(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        .expandingTildeInPath
      guard !path.isEmpty else {
        return .init(
          path: nil, attempted: [], invalidReason: "The configured executable path is empty.")
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        return .init(
          path: nil, attempted: [path],
          invalidReason: "The configured executable does not exist: \(path)")
      }
      guard FileManager.default.isExecutableFile(atPath: path) else {
        return .init(
          path: nil, attempted: [path],
          invalidReason: "The configured file is not executable: \(path)")
      }
      return .init(path: URL(fileURLWithPath: path).standardizedFileURL.path, attempted: [path])
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
      guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
      let process = Process()
      let output = Pipe()
      let finished = DispatchSemaphore(value: 0)
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.standardOutput = output
      process.standardError = Pipe()
      process.terminationHandler = { _ in finished.signal() }
      do {
        try process.run()
        guard finished.wait(timeout: .now() + 2) == .success else {
          if process.isRunning { process.terminate() }
          _ = finished.wait(timeout: .now() + .milliseconds(250))
          return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let value = String(
          decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
      } catch {
        if process.isRunning { process.terminate() }
        return nil
      }
    }
  }

  private enum EditorSyntaxLibraryDiscovery {
    struct Resolution {
      var configuration: EditorSyntaxLibraryConfiguration?
      var attempted: [String]
    }

    static func resolve(
      language: EditorLanguage,
      profile: EditorLanguage.Profile,
      environment: [String: String]
    ) -> Resolution {
      if let value = environment[profile.syntaxEnvironmentKey], !value.isEmpty {
        let url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        return .init(configuration: .init(libraryURL: url), attempted: [url.path])
      }

      let home = FileManager.default.homeDirectoryForCurrentUser.path
      let directories = [
        "\(home)/Library/Application Support/EditorServices/Grammars",
        "\(home)/.local/lib/editorservices/grammars",
        "\(home)/.local/lib",
        "/opt/homebrew/lib",
        "/usr/local/lib",
        "/usr/lib",
      ]
      #if os(macOS)
        let suffixes = ["dylib", "so"]
      #else
        let suffixes = ["so"]
      #endif
      var attempted: [String] = []
      for directory in directories {
        for suffix in suffixes {
          for base in [
            "libtree-sitter-\(profile.grammarName)", "tree-sitter-\(profile.grammarName)",
          ] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("\(base).\(suffix)")
              .path
            attempted.append(path)
            if FileManager.default.fileExists(atPath: path) {
              return .init(
                configuration: .init(libraryURL: URL(fileURLWithPath: path)), attempted: attempted)
            }
          }
        }
      }
      return .init(configuration: nil, attempted: attempted)
    }
  }

  extension EditorLanguage {
    fileprivate struct Profile {
      var serverID: String
      var displayName: String
      var executableNames: [String]
      var environmentKeys: [String]
      var extraExecutablePaths: [String]
      var useXcrun: Bool
      var languageIDs: Set<String>
      var fileExtensions: Set<String>
      var grammarName: String
      var syntaxSymbol: String
      var installSuggestion: String
      var makeServer: @Sendable (String) -> ExternalLanguageServerConfiguration
      var requiredProjectMarkers: Set<String> = []

      var syntaxEnvironmentKey: String {
        "TREE_SITTER_\(rawEnvironmentToken(grammarName))_LIBRARY"
      }

      private func rawEnvironmentToken(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "-", with: "_")
      }
    }

    fileprivate static func profile(for language: EditorLanguage) -> Profile {
      switch language {
      case .swift:
        return .init(
          serverID: "sourcekit-lsp", displayName: "SourceKit-LSP",
          executableNames: ["sourcekit-lsp"], environmentKeys: ["SOURCEKIT_LSP_PATH"],
          extraExecutablePaths: [
            "/usr/bin/sourcekit-lsp",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/sourcekit-lsp",
            "/usr/local/swift/usr/bin/sourcekit-lsp",
          ], useXcrun: true, languageIDs: ["swift"], fileExtensions: ["swift"],
          grammarName: "swift", syntaxSymbol: "tree_sitter_swift",
          installSuggestion:
            "Install a Swift toolchain containing sourcekit-lsp or set SOURCEKIT_LSP_PATH.",
          makeServer: { ExternalLanguageServerPresets.swift(executable: $0) })
      case .c, .cpp, .objectiveC, .objectiveCPP:
        return .init(
          serverID: "clangd", displayName: "clangd", executableNames: ["clangd", "ccls"],
          environmentKeys: ["CLANGD_PATH"],
          extraExecutablePaths: [
            "/opt/homebrew/opt/llvm/bin/clangd", "/usr/local/opt/llvm/bin/clangd",
            "/usr/bin/clangd",
          ], useXcrun: true, languageIDs: ["c", "cpp", "objective-c", "objective-cpp"],
          fileExtensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm"],
          grammarName: language.rawValue,
          syntaxSymbol:
            "tree_sitter_\(language == .objectiveC ? "objc" : language.rawValue.replacingOccurrences(of: "-", with: "_"))",
          installSuggestion: "Install LLVM clangd (or ccls) and ensure it is on PATH.",
          makeServer: { path in
            path.hasSuffix("ccls")
              ? ExternalLanguageServerPresets.ccls(executable: path)
              : ExternalLanguageServerPresets.clangd(
                executable: path,
                arguments: ["--background-index", "--clang-tidy", "--completion-style=detailed"])
          })
      case .python:
        return .init(
          serverID: "python-lsp", displayName: "Python LSP",
          executableNames: ["basedpyright-langserver", "pyright-langserver", "pylsp"],
          environmentKeys: ["PYRIGHT_LANGSERVER_PATH", "PYTHON_LSP_PATH"], extraExecutablePaths: [],
          useXcrun: false, languageIDs: ["python"], fileExtensions: ["py", "pyi", "pyw"],
          grammarName: "python", syntaxSymbol: "tree_sitter_python",
          installSuggestion:
            "Install basedpyright, pyright, or python-lsp-server and expose its executable on PATH.",
          makeServer: { path in
            path.hasSuffix("pylsp")
              ? ExternalLanguageServerPresets.pythonLSP(executable: path)
              : (path.contains("basedpyright")
                ? ExternalLanguageServerPresets.custom(
                  id: "basedpyright", executable: path, arguments: ["--stdio"],
                  languageIDs: ["python"])
                : ExternalLanguageServerPresets.pyright(executable: path))
          })
      case .rust:
        var value = simple(
          language, serverID: "rust-analyzer", displayName: "rust-analyzer",
          names: ["rust-analyzer"], env: ["RUST_ANALYZER_PATH"], grammar: "rust",
          symbol: "tree_sitter_rust",
          suggestion: "Install rust-analyzer, commonly through rustup component add rust-analyzer.",
          make: { ExternalLanguageServerPresets.rustAnalyzer(executable: $0) })
        value.requiredProjectMarkers = ["Cargo.toml", "rust-project.json"]
        return value
      case .go:
        return simple(
          language, serverID: "gopls", displayName: "gopls", names: ["gopls"], env: ["GOPLS_PATH"],
          grammar: "go", symbol: "tree_sitter_go",
          suggestion: "Install gopls and ensure the Go bin directory is on PATH.",
          make: { ExternalLanguageServerPresets.gopls(executable: $0) })
      case .java:
        return simple(
          language, serverID: "jdtls", displayName: "Eclipse JDT LS", names: ["jdtls"],
          env: ["JDTLS_PATH"], grammar: "java", symbol: "tree_sitter_java",
          suggestion: "Install Eclipse JDT Language Server or a jdtls launcher and put it on PATH.",
          make: { ExternalLanguageServerPresets.java(executable: $0) })
      case .kotlin:
        return simple(
          language, serverID: "kotlin-language-server", displayName: "Kotlin Language Server",
          names: ["kotlin-language-server", "kotlin-lsp"],
          env: ["KOTLIN_LANGUAGE_SERVER_PATH", "KOTLIN_LSP_PATH"], grammar: "kotlin",
          symbol: "tree_sitter_kotlin",
          suggestion:
            "Install kotlin-language-server or Kotlin LSP and configure its launcher path.",
          make: { ExternalLanguageServerPresets.kotlin(executable: $0) })
      case .javascript, .typescript:
        return .init(
          serverID: "typescript-language-server", displayName: "TypeScript Language Server",
          executableNames: ["typescript-language-server"],
          environmentKeys: ["TYPESCRIPT_LANGUAGE_SERVER_PATH"], extraExecutablePaths: [],
          useXcrun: false,
          languageIDs: ["javascript", "javascriptreact", "typescript", "typescriptreact"],
          fileExtensions: ["js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"],
          grammarName: language == .javascript ? "javascript" : "typescript",
          syntaxSymbol: language == .javascript
            ? "tree_sitter_javascript" : "tree_sitter_typescript",
          installSuggestion:
            "Install typescript-language-server and TypeScript, then expose the launcher on PATH.",
          makeServer: { ExternalLanguageServerPresets.typescript(executable: $0) })
      case .html:
        return simple(
          language, serverID: "html-language-server", displayName: "HTML Language Server",
          names: ["vscode-html-language-server"], env: ["HTML_LANGUAGE_SERVER_PATH"],
          grammar: "html", symbol: "tree_sitter_html",
          suggestion:
            "Install vscode-langservers-extracted and expose vscode-html-language-server on PATH.",
          make: { ExternalLanguageServerPresets.html(executable: $0) })
      case .css:
        return .init(
          serverID: "css-language-server", displayName: "CSS Language Server",
          executableNames: ["vscode-css-language-server"],
          environmentKeys: ["CSS_LANGUAGE_SERVER_PATH"], extraExecutablePaths: [], useXcrun: false,
          languageIDs: ["css", "scss", "less"], fileExtensions: ["css", "scss", "less"],
          grammarName: "css", syntaxSymbol: "tree_sitter_css",
          installSuggestion:
            "Install vscode-langservers-extracted and expose vscode-css-language-server on PATH.",
          makeServer: { ExternalLanguageServerPresets.css(executable: $0) })
      case .json:
        return .init(
          serverID: "json-language-server", displayName: "JSON Language Server",
          executableNames: ["vscode-json-language-server"],
          environmentKeys: ["JSON_LANGUAGE_SERVER_PATH"], extraExecutablePaths: [], useXcrun: false,
          languageIDs: ["json", "jsonc"], fileExtensions: ["json", "jsonc"], grammarName: "json",
          syntaxSymbol: "tree_sitter_json",
          installSuggestion:
            "Install vscode-langservers-extracted and expose vscode-json-language-server on PATH.",
          makeServer: { ExternalLanguageServerPresets.json(executable: $0) })
      case .yaml:
        return simple(
          language, serverID: "yaml-language-server", displayName: "YAML Language Server",
          names: ["yaml-language-server"], env: ["YAML_LANGUAGE_SERVER_PATH"], grammar: "yaml",
          symbol: "tree_sitter_yaml",
          suggestion: "Install yaml-language-server and expose it on PATH.",
          make: { ExternalLanguageServerPresets.yaml(executable: $0) })
      case .shellscript:
        return .init(
          serverID: "bash-language-server", displayName: "Bash Language Server",
          executableNames: ["bash-language-server"], environmentKeys: ["BASH_LANGUAGE_SERVER_PATH"],
          extraExecutablePaths: [], useXcrun: false, languageIDs: ["shellscript"],
          fileExtensions: ["sh", "bash", "zsh"], grammarName: "bash",
          syntaxSymbol: "tree_sitter_bash",
          installSuggestion: "Install bash-language-server and expose it on PATH.",
          makeServer: { ExternalLanguageServerPresets.bash(executable: $0) })
      case .lua:
        return simple(
          language, serverID: "lua-language-server", displayName: "Lua Language Server",
          names: ["lua-language-server"], env: ["LUA_LANGUAGE_SERVER_PATH"], grammar: "lua",
          symbol: "tree_sitter_lua",
          suggestion: "Install lua-language-server and expose it on PATH.",
          make: { ExternalLanguageServerPresets.lua(executable: $0) })
      case .ruby:
        return simple(
          language, serverID: "solargraph", displayName: "Solargraph", names: ["solargraph"],
          env: ["SOLARGRAPH_PATH"], grammar: "ruby", symbol: "tree_sitter_ruby",
          suggestion: "Install the solargraph gem and expose it on PATH.",
          make: { ExternalLanguageServerPresets.ruby(executable: $0) })
      case .php:
        return simple(
          language, serverID: "intelephense", displayName: "Intelephense", names: ["intelephense"],
          env: ["INTELEPHENSE_PATH"], grammar: "php", symbol: "tree_sitter_php",
          suggestion: "Install intelephense and expose it on PATH.",
          make: { ExternalLanguageServerPresets.php(executable: $0) })
      case .csharp:
        return simple(
          language, serverID: "omnisharp", displayName: "OmniSharp",
          names: ["OmniSharp", "omnisharp"], env: ["OMNISHARP_PATH"], grammar: "c-sharp",
          symbol: "tree_sitter_c_sharp",
          suggestion: "Install OmniSharp and configure its executable path.",
          make: { ExternalLanguageServerPresets.csharp(executable: $0) })
      case .haskell:
        return simple(
          language, serverID: "haskell-language-server", displayName: "Haskell Language Server",
          names: ["haskell-language-server-wrapper", "haskell-language-server"],
          env: ["HASKELL_LANGUAGE_SERVER_PATH"], grammar: "haskell", symbol: "tree_sitter_haskell",
          suggestion: "Install Haskell Language Server and expose its wrapper on PATH.",
          make: { ExternalLanguageServerPresets.haskell(executable: $0) })
      case .ocaml:
        return simple(
          language, serverID: "ocamllsp", displayName: "OCaml LSP", names: ["ocamllsp"],
          env: ["OCAMLLSP_PATH"], grammar: "ocaml", symbol: "tree_sitter_ocaml",
          suggestion: "Install ocaml-lsp-server and expose ocamllsp on PATH.",
          make: { ExternalLanguageServerPresets.ocaml(executable: $0) })
      case .scala:
        return custom(
          language, serverID: "metals", displayName: "Metals", names: ["metals"],
          env: ["METALS_PATH"], grammar: "scala", symbol: "tree_sitter_scala",
          suggestion: "Install Metals and expose it on PATH.")
      case .clojure:
        return custom(
          language, serverID: "clojure-lsp", displayName: "Clojure LSP", names: ["clojure-lsp"],
          env: ["CLOJURE_LSP_PATH"], grammar: "clojure", symbol: "tree_sitter_clojure",
          suggestion: "Install clojure-lsp and expose it on PATH.")
      case .elixir:
        return custom(
          language, serverID: "elixir-ls", displayName: "ElixirLS",
          names: ["elixir-ls", "language_server.sh"], env: ["ELIXIR_LS_PATH"], grammar: "elixir",
          symbol: "tree_sitter_elixir",
          suggestion: "Install ElixirLS and configure its language-server launcher path.")
      case .erlang:
        return custom(
          language, serverID: "erlang-ls", displayName: "Erlang Language Server",
          names: ["elp", "erlang_ls"], env: ["ERLANG_LS_PATH", "ELP_PATH"], grammar: "erlang",
          symbol: "tree_sitter_erlang",
          suggestion: "Install ELP or erlang_ls and expose it on PATH.")
      case .dart:
        return custom(
          language, serverID: "dart-language-server", displayName: "Dart Language Server",
          names: ["dart"], env: ["DART_PATH"], arguments: ["language-server", "--protocol=lsp"],
          grammar: "dart", symbol: "tree_sitter_dart",
          suggestion: "Install the Dart SDK and expose dart on PATH.")
      case .nim:
        return custom(
          language, serverID: "nimlangserver", displayName: "Nim Language Server",
          names: ["nimlangserver"], env: ["NIMLANGSERVER_PATH"], grammar: "nim",
          symbol: "tree_sitter_nim", suggestion: "Install nimlangserver and expose it on PATH.")
      case .markdown:
        return custom(
          language, serverID: "marksman", displayName: "Marksman", names: ["marksman"],
          env: ["MARKSMAN_PATH"], grammar: "markdown", symbol: "tree_sitter_markdown",
          suggestion: "Install Marksman and expose it on PATH.")
      case .xml:
        return custom(
          language, serverID: "lemminx", displayName: "LemMinX", names: ["lemminx"],
          env: ["LEMMINX_PATH"], grammar: "xml", symbol: "tree_sitter_xml",
          suggestion: "Install LemMinX and expose its launcher on PATH.")
      case .sql:
        return custom(
          language, serverID: "sqls", displayName: "SQL Language Server", names: ["sqls"],
          env: ["SQLS_PATH"], grammar: "sql", symbol: "tree_sitter_sql",
          suggestion: "Install sqls and expose it on PATH.")
      case .dockerfile:
        return simple(
          language, serverID: "docker-langserver", displayName: "Dockerfile Language Server",
          names: ["docker-langserver"], env: ["DOCKER_LANGSERVER_PATH"], grammar: "dockerfile",
          symbol: "tree_sitter_dockerfile",
          suggestion:
            "Install dockerfile-language-server-nodejs and expose docker-langserver on PATH.",
          make: {
            ExternalLanguageServerPresets.custom(
              id: "docker-langserver", executable: $0, arguments: ["--stdio"],
              languageIDs: ["dockerfile"])
          })
      case .protobuf:
        return custom(
          language, serverID: "bufls", displayName: "Protocol Buffer Language Server",
          names: ["bufls"], env: ["BUFLS_PATH"], grammar: "proto", symbol: "tree_sitter_proto",
          suggestion: "Install bufls and expose it on PATH.")
      case .graphql:
        return custom(
          language, serverID: "graphql-lsp", displayName: "GraphQL Language Server",
          names: ["graphql-lsp"], env: ["GRAPHQL_LSP_PATH"], arguments: ["server", "-m", "stream"],
          grammar: "graphql", symbol: "tree_sitter_graphql",
          suggestion: "Install graphql-language-service-cli and expose graphql-lsp on PATH.")
      case .vue:
        return custom(
          language, serverID: "vue-language-server", displayName: "Vue Language Server",
          names: ["vue-language-server"], env: ["VUE_LANGUAGE_SERVER_PATH"], arguments: ["--stdio"],
          grammar: "vue", symbol: "tree_sitter_vue",
          suggestion: "Install @vue/language-server and expose vue-language-server on PATH.")
      case .svelte:
        return custom(
          language, serverID: "svelte-language-server", displayName: "Svelte Language Server",
          names: ["svelteserver"], env: ["SVELTE_LANGUAGE_SERVER_PATH"], arguments: ["--stdio"],
          grammar: "svelte", symbol: "tree_sitter_svelte",
          suggestion: "Install svelte-language-server and expose svelteserver on PATH.")
      case .fsharp:
        return custom(
          language, serverID: "fsautocomplete", displayName: "FsAutoComplete",
          names: ["fsautocomplete"], env: ["FSAC_PATH"], arguments: ["--mode", "lsp"],
          grammar: "fsharp", symbol: "tree_sitter_fsharp",
          suggestion: "Install FsAutoComplete and expose fsautocomplete on PATH.")
      case .zig:
        return simple(
          language, serverID: "zls", displayName: "Zig Language Server", names: ["zls"],
          env: ["ZLS_PATH"], grammar: "zig", symbol: "tree_sitter_zig",
          suggestion: "Install zls and expose it on PATH.",
          make: { ExternalLanguageServerPresets.zig(executable: $0) })
      case .terraform:
        return .init(
          serverID: "terraform-ls", displayName: "Terraform Language Server",
          executableNames: ["terraform-ls"], environmentKeys: ["TERRAFORM_LS_PATH"],
          extraExecutablePaths: [], useXcrun: false, languageIDs: ["terraform"],
          fileExtensions: ["tf", "tfvars", "hcl"], grammarName: "hcl",
          syntaxSymbol: "tree_sitter_hcl",
          installSuggestion: "Install terraform-ls and expose it on PATH.",
          makeServer: { ExternalLanguageServerPresets.terraform(executable: $0) })
      }
    }

    private static func custom(
      _ language: EditorLanguage,
      serverID: String,
      displayName: String,
      names: [String],
      env: [String],
      arguments: [String] = [],
      grammar: String,
      symbol: String,
      suggestion: String
    ) -> Profile {
      simple(
        language,
        serverID: serverID,
        displayName: displayName,
        names: names,
        env: env,
        grammar: grammar,
        symbol: symbol,
        suggestion: suggestion,
        make: { path in
          ExternalLanguageServerPresets.custom(
            id: LanguageServiceID(rawValue: serverID),
            executable: path,
            arguments: arguments,
            languageIDs: language.languageIDs,
            fileExtensions: language.fileExtensions
          )
        }
      )
    }

    private static func simple(
      _ language: EditorLanguage,
      serverID: String,
      displayName: String,
      names: [String],
      env: [String],
      grammar: String,
      symbol: String,
      suggestion: String,
      make: @escaping @Sendable (String) -> ExternalLanguageServerConfiguration
    ) -> Profile {
      let definition = EditorLanguageCatalog.standard.definitions.first {
        $0.id == language.rawValue
      }
      return .init(
        serverID: serverID,
        displayName: displayName,
        executableNames: names,
        environmentKeys: env,
        extraExecutablePaths: [],
        useXcrun: false,
        languageIDs: definition.map { [$0.id] } ?? [language.rawValue],
        fileExtensions: definition?.fileExtensions ?? [],
        grammarName: grammar,
        syntaxSymbol: symbol,
        installSuggestion: suggestion,
        makeServer: make
      )
    }
  }
#endif
