import EditorCore
import EditorServiceKit
import EditorWorkspace
import Foundation

/// Builds a ``SwiftEditorBackend`` from independently supplied editor services.
///
/// The builder depends on protocols rather than SourceKit-LSP, Tree-sitter, or a particular
/// transport. This makes the same composition API usable for local processes, remote services,
/// test doubles, and supplemental analyzers.
public struct EditorBackendBuilder: Sendable {
  public var workspaceURL: URL
  public var languageID: String
  public var syntaxFactory: SwiftEditorBackend.SyntaxFactory?
  public var contextualSyntaxFactory: SwiftEditorBackend.ContextualSyntaxFactory?
  public var completionStrategy: SwiftEditorCompletionStrategy
  public var completionLimit: Int
  public var sourceWorkspaceConfiguration: SourceWorkspaceConfiguration
  public var processEnvironment: [String: String]
  public var scanSourceWorkspaceOnConstruction: Bool
  public var sourceWorkspaceMonitoringInterval: Duration?

  private var languageServices: [LanguageServiceRegistration]

  public init(
    workspaceURL: URL,
    languageID: String = "swift",
    syntaxFactory: SwiftEditorBackend.SyntaxFactory? = nil,
    contextualSyntaxFactory: SwiftEditorBackend.ContextualSyntaxFactory? = nil,
    completionStrategy: SwiftEditorCompletionStrategy = .mergeKeywordsAndFallbackOnError,
    completionLimit: Int = 100,
    sourceWorkspaceConfiguration: SourceWorkspaceConfiguration = .init(),
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    scanSourceWorkspaceOnConstruction: Bool = true,
    sourceWorkspaceMonitoringInterval: Duration? = nil
  ) {
    self.workspaceURL = workspaceURL
    self.languageID = languageID
    self.syntaxFactory = syntaxFactory
    self.contextualSyntaxFactory = contextualSyntaxFactory
    self.completionStrategy = completionStrategy
    self.completionLimit = max(1, completionLimit)
    self.sourceWorkspaceConfiguration = sourceWorkspaceConfiguration
    self.processEnvironment = processEnvironment
    self.scanSourceWorkspaceOnConstruction = scanSourceWorkspaceOnConstruction
    self.sourceWorkspaceMonitoringInterval = sourceWorkspaceMonitoringInterval
    self.languageServices = []
  }

  /// Selects syntax providers per document. When this returns `nil`, the legacy `syntaxFactory`
  /// is used as a fallback.
  public func withContextualSyntaxFactory(
    _ factory: SwiftEditorBackend.ContextualSyntaxFactory?
  ) -> Self {
    var copy = self
    copy.contextualSyntaxFactory = factory
    return copy
  }

  /// Adds a service to this value and returns the resulting builder for fluent composition.
  public func addingLanguageService(_ registration: LanguageServiceRegistration) -> Self {
    var copy = self
    copy.languageServices.append(registration)
    return copy
  }

  /// Adds a service in-place when the builder is stored as a mutable variable.
  public mutating func addLanguageService(_ registration: LanguageServiceRegistration) {
    languageServices.append(registration)
  }

  public var languageServiceCount: Int { languageServices.count }

  /// Creates the router and backend, scans the workspace, and starts monitoring when configured.
  public func build() async throws -> SwiftEditorBackend {
    // Builders always install a router, even when initially empty, so applications can
    // discover and register plug-ins after the backend has already been constructed.
    let router = try await LanguageServiceRouter(registrations: languageServices)

    let backend = SwiftEditorBackend(
      workspaceURL: workspaceURL,
      languageID: languageID,
      languageService: router,
      syntaxFactory: syntaxFactory,
      contextualSyntaxFactory: contextualSyntaxFactory,
      completionStrategy: completionStrategy,
      completionLimit: completionLimit,
      sourceWorkspaceConfiguration: sourceWorkspaceConfiguration,
      processEnvironment: processEnvironment,
      languageServerShutdown: {
        try await router.shutdown()
      }
    )

    do {
      if scanSourceWorkspaceOnConstruction { _ = try await backend.scanSourceWorkspace() }
      if let interval = sourceWorkspaceMonitoringInterval {
        await backend.startSourceWorkspaceMonitoring(every: interval)
      }
      return backend
    } catch {
      try? await router.shutdown()
      throw error
    }
  }
}
