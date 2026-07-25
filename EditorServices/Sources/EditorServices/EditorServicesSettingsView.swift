#if canImport(SwiftUI) && canImport(Combine)
  import Combine
  import Foundation
  import SwiftUI

  public enum EditorServicesSettingsLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case manual

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .automatic: return "Automatic"
      case .manual: return "Manual"
      }
    }
  }

  public enum EditorServicesSettingsPhase: Equatable, Sendable {
    case idle
    case inspecting
    case ready
    case failed(String)
  }

  /// Observable settings state for ``EditorServicesSettingsView``.
  ///
  /// The model owns editable paths and selection state, but never starts a service merely because
  /// a field changed. Call ``refreshInspection()`` for a process-free preflight or
  /// ``makeBackend()`` when the application explicitly applies the settings.
  @MainActor
  public final class EditorServicesSettingsModel: ObservableObject {
    @Published public var workspaceURL: URL
    @Published public var languageMode: EditorServicesSettingsLanguageMode
    @Published public var manualLanguages: Set<EditorLanguage>
    @Published public var automaticallyIncludedLanguages: Set<EditorLanguage>
    @Published public var automaticallyExcludedLanguages: Set<EditorLanguage>
    @Published public var languageServersEnabled: Bool
    @Published public var syntaxEnabled: Bool
    @Published public var debuggingEnabled: Bool
    @Published public var requirementPolicy: EditorServiceRequirementPolicy
    @Published public var languageServerPaths: [EditorLanguage: String]
    @Published public var debugAdapterPaths: [EditorLanguage: String]
    @Published public var syntaxLibraryPaths: [EditorLanguage: String]
    @Published public var projectInspectionConfiguration: EditorProjectInspectionConfiguration

    @Published public private(set) var inspection: EditorServiceInspectionResult?
    @Published public private(set) var phase: EditorServicesSettingsPhase = .idle

    private var template: EditorServicesConfiguration
    private var syntaxTemplates: [EditorLanguage: EditorSyntaxLibraryConfiguration]

    public init(
      workspaceURL: URL,
      languageSelection: EditorLanguageSelection = .automatic
    ) {
      self.template = .init(workspaceURL: workspaceURL, languageSelection: languageSelection)
      self.workspaceURL = workspaceURL
      self.projectInspectionConfiguration = .init()
      self.languageServersEnabled = true
      self.syntaxEnabled = true
      self.debuggingEnabled = true
      self.requirementPolicy = .bestEffort
      self.languageServerPaths = [:]
      self.debugAdapterPaths = [:]
      self.syntaxLibraryPaths = [:]
      self.syntaxTemplates = [:]

      switch languageSelection {
      case .automatic:
        self.languageMode = .automatic
        self.manualLanguages = []
        self.automaticallyIncludedLanguages = []
        self.automaticallyExcludedLanguages = []
      case .automaticWithOverrides(let included, let excluded):
        self.languageMode = .automatic
        self.manualLanguages = []
        self.automaticallyIncludedLanguages = included
        self.automaticallyExcludedLanguages = excluded
      case .manual(let languages):
        self.languageMode = .manual
        self.manualLanguages = languages
        self.automaticallyIncludedLanguages = []
        self.automaticallyExcludedLanguages = []
      }
    }

    public init(configuration: EditorServicesConfiguration) {
      self.template = configuration
      self.workspaceURL = configuration.workspaceURL
      self.projectInspectionConfiguration = configuration.projectInspectionConfiguration
      self.languageServersEnabled = configuration.features.languageServers
      self.syntaxEnabled = configuration.features.syntax
      self.debuggingEnabled = configuration.features.debugging
      self.requirementPolicy = configuration.requirementPolicy
      self.languageServerPaths = configuration.overrides.languageServerExecutables
      self.debugAdapterPaths = configuration.overrides.debugAdapterExecutables
      self.syntaxTemplates = configuration.overrides.syntaxLibraries
      self.syntaxLibraryPaths = configuration.overrides.syntaxLibraries.mapValues(\.libraryURL.path)

      switch configuration.languageSelection {
      case .automatic:
        self.languageMode = .automatic
        self.manualLanguages = []
        self.automaticallyIncludedLanguages = []
        self.automaticallyExcludedLanguages = []
      case .automaticWithOverrides(let included, let excluded):
        self.languageMode = .automatic
        self.manualLanguages = []
        self.automaticallyIncludedLanguages = included
        self.automaticallyExcludedLanguages = excluded
      case .manual(let languages):
        self.languageMode = .manual
        self.manualLanguages = languages
        self.automaticallyIncludedLanguages = []
        self.automaticallyExcludedLanguages = []
      }
    }

    public var languageSelection: EditorLanguageSelection {
      switch languageMode {
      case .automatic:
        return .automatic(
          including: automaticallyIncludedLanguages,
          excluding: automaticallyExcludedLanguages
        )
      case .manual:
        return .manual(manualLanguages)
      }
    }

    public var detectedLanguages: Set<EditorLanguage> {
      inspection?.projectInspection?.languages ?? []
    }

    public var effectiveLanguages: Set<EditorLanguage> {
      switch languageMode {
      case .manual:
        return manualLanguages
      case .automatic:
        return
          detectedLanguages
          .union(automaticallyIncludedLanguages)
          .subtracting(automaticallyExcludedLanguages)
      }
    }

    public var visibleLanguages: [EditorLanguage] {
      let preferred = effectiveLanguages.union(detectedLanguages)
      let remaining = Set(EditorLanguage.allCases).subtracting(preferred)
      return preferred.sorted(by: languageSort).map { $0 }
        + remaining.sorted(by: languageSort).map { $0 }
    }

    public func isLanguageEnabled(_ language: EditorLanguage) -> Bool {
      effectiveLanguages.contains(language)
    }

    public func setLanguage(_ language: EditorLanguage, enabled: Bool) {
      switch languageMode {
      case .manual:
        if enabled { manualLanguages.insert(language) } else { manualLanguages.remove(language) }
      case .automatic:
        if enabled {
          automaticallyExcludedLanguages.remove(language)
          if !detectedLanguages.contains(language) {
            automaticallyIncludedLanguages.insert(language)
          }
        } else {
          automaticallyIncludedLanguages.remove(language)
          automaticallyExcludedLanguages.insert(language)
        }
      }
    }

    public func configuration() -> EditorServicesConfiguration {
      var value = template
      value.workspaceURL = workspaceURL
      value.languageSelection = languageSelection
      value.projectInspectionConfiguration = projectInspectionConfiguration
      value.features = .init(
        languageServers: languageServersEnabled,
        syntax: syntaxEnabled,
        debugging: debuggingEnabled
      )
      value.requirementPolicy = requirementPolicy

      var syntaxLibraries: [EditorLanguage: EditorSyntaxLibraryConfiguration] = [:]
      for (language, rawPath) in syntaxLibraryPaths {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { continue }
        var configured = syntaxTemplates[language] ?? .init(libraryURL: URL(fileURLWithPath: path))
        configured.libraryURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        syntaxLibraries[language] = configured
      }

      value.overrides = .init(
        languageServerExecutables: cleaned(languageServerPaths),
        debugAdapterExecutable: template.overrides.debugAdapterExecutable,
        debugAdapterExecutables: cleaned(debugAdapterPaths),
        debugAdapterArguments: template.overrides.debugAdapterArguments,
        syntaxLibraries: syntaxLibraries
      )
      return value
    }

    public func refreshInspection() async {
      phase = .inspecting
      do {
        #if os(macOS)
          let result = try await EditorServiceBootstrap.inspect(configuration: configuration())
          inspection = result
          phase = .ready
        #else
          inspection = nil
          phase = .failed("External language servers and debug adapters require macOS.")
        #endif
      } catch {
        inspection = nil
        phase = .failed(error.localizedDescription)
      }
    }

    public func inspectIfNeeded() async {
      guard inspection == nil, phase != .inspecting else { return }
      await refreshInspection()
    }

    #if os(macOS)
      public func makeBackend() async throws -> EditorServiceBootstrapResult {
        try await EditorServiceBootstrap.initialize(configuration: configuration())
      }
    #endif

    public func diagnostic(
      for language: EditorLanguage,
      feature: EditorServiceFeature
    ) -> EditorServiceDiagnostic? {
      inspection?.report.diagnostics(for: language, feature: feature).first
    }

    private func cleaned(_ values: [EditorLanguage: String]) -> [EditorLanguage: String] {
      values.reduce(into: [:]) { result, item in
        let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { result[item.key] = value }
      }
    }

    private func languageSort(_ lhs: EditorLanguage, _ rhs: EditorLanguage) -> Bool {
      lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  /// A settings detail view designed to be placed directly inside a `NavigationSplitView`.
  public struct EditorServicesSettingsView: View {
    @StateObject private var model: EditorServicesSettingsModel
    private let onApply: ((EditorServicesConfiguration) -> Void)?

    public init(
      model: EditorServicesSettingsModel,
      onApply: ((EditorServicesConfiguration) -> Void)? = nil
    ) {
      _model = StateObject(wrappedValue: model)
      self.onApply = onApply
    }

    /// Creates a self-contained settings screen with automatic project inspection enabled.
    public init(
      workspaceURL: URL,
      languageSelection: EditorLanguageSelection = .automatic,
      onApply: ((EditorServicesConfiguration) -> Void)? = nil
    ) {
      _model = StateObject(
        wrappedValue: EditorServicesSettingsModel(
          workspaceURL: workspaceURL,
          languageSelection: languageSelection
        )
      )
      self.onApply = onApply
    }

    public var body: some View {
      Form {
        projectSection
        featureSection
        languageSection
        availabilitySection
        overrideSection
        applySection
      }
      .formStyle(.grouped)
      .navigationTitle("Editor Services")
      .task { await model.inspectIfNeeded() }
    }

    private var projectSection: some View {
      Section("Opened Project") {
        LabeledContent("Path") {
          Text(model.workspaceURL.path)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        Picker("Language Selection", selection: $model.languageMode) {
          ForEach(EditorServicesSettingsLanguageMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        HStack {
          phaseLabel
          Spacer()
          Button("Inspect Again") {
            Task { await model.refreshInspection() }
          }
          .disabled(model.phase == .inspecting)
        }

        if let project = model.inspection?.projectInspection {
          LabeledContent("Files Inspected", value: project.scannedFileCount.formatted())
          if project.wasTruncated {
            Label(
              "Inspection reached the configured file limit.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
          }
        }

        DisclosureGroup("Inspection Options") {
          Toggle(
            "Inspect Project Markers",
            isOn: $model.projectInspectionConfiguration.inspectProjectMarkers
          )
          Toggle(
            "Include Hidden Items",
            isOn: $model.projectInspectionConfiguration.includeHiddenItems
          )
          Toggle(
            "Follow Internal Symbolic Links",
            isOn: $model.projectInspectionConfiguration.followSymbolicLinks
          )
          Stepper(
            "Maximum Files: \(model.projectInspectionConfiguration.maximumFileCount.formatted())",
            value: $model.projectInspectionConfiguration.maximumFileCount,
            in: 1...1_000_000,
            step: 1_000
          )
        }
      }
    }

    private var featureSection: some View {
      Section("Features") {
        Toggle("Language Servers", isOn: $model.languageServersEnabled)
        Toggle("Tree-sitter Syntax", isOn: $model.syntaxEnabled)
        Toggle("Debug Adapters", isOn: $model.debuggingEnabled)

        Picker("Requirement Policy", selection: $model.requirementPolicy) {
          Text("Best Effort").tag(EditorServiceRequirementPolicy.bestEffort)
          Text("Require LSP").tag(EditorServiceRequirementPolicy.requireLanguageServers)
          Text("Strict").tag(EditorServiceRequirementPolicy.strict)
        }
      }
    }

    private var languageSection: some View {
      Section {
        ForEach(model.visibleLanguages) { language in
          Toggle(isOn: languageBinding(language)) {
            HStack {
              Text(language.displayName)
              if model.detectedLanguages.contains(language) {
                Text(detectionSummary(for: language))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else if model.automaticallyIncludedLanguages.contains(language) {
                Text("Included")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      } header: {
        Text("Languages")
      } footer: {
        if model.languageMode == .automatic {
          Text(
            "Detected languages are enabled automatically. Toggles remain explicit include/exclude overrides."
          )
        } else {
          Text("Manual mode enables exactly the selected languages.")
        }
      }
    }

    @ViewBuilder
    private var availabilitySection: some View {
      Section("Service Availability") {
        if model.effectiveLanguages.isEmpty {
          Text("No supported project languages are selected.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.effectiveLanguages.sorted { $0.displayName < $1.displayName }) { language in
            DisclosureGroup(language.displayName) {
              diagnosticRow(
                title: "Language Server",
                diagnostic: model.diagnostic(for: language, feature: .languageServer)
              )
              diagnosticRow(
                title: "Syntax",
                diagnostic: model.diagnostic(for: language, feature: .syntax)
              )
              diagnosticRow(
                title: "Debugger",
                diagnostic: model.diagnostic(for: language, feature: .debugAdapter)
              )
            }
          }
        }
      }
    }

    @ViewBuilder
    private var overrideSection: some View {
      Section {
        ForEach(model.effectiveLanguages.sorted { $0.displayName < $1.displayName }) { language in
          DisclosureGroup(language.displayName) {
            TextField(
              "Language server executable",
              text: dictionaryBinding($model.languageServerPaths, key: language)
            )
            .textFieldStyle(.roundedBorder)

            TextField(
              "Debug adapter executable",
              text: dictionaryBinding($model.debugAdapterPaths, key: language)
            )
            .textFieldStyle(.roundedBorder)

            TextField(
              "Tree-sitter library",
              text: dictionaryBinding($model.syntaxLibraryPaths, key: language)
            )
            .textFieldStyle(.roundedBorder)
          }
        }
      } header: {
        Text("Manual Paths")
      } footer: {
        Text(
          "Leave a field empty to use automatic discovery. A non-empty path is authoritative and produces an actionable error when invalid."
        )
      }
    }

    @ViewBuilder
    private var applySection: some View {
      if let onApply {
        Section {
          Button("Apply Settings") {
            onApply(model.configuration())
          }
          .disabled(model.phase == .inspecting)
        }
      }
    }

    @ViewBuilder
    private var phaseLabel: some View {
      switch model.phase {
      case .idle:
        Label("Not inspected", systemImage: "circle")
          .foregroundStyle(.secondary)
      case .inspecting:
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Inspecting")
        }
      case .ready:
        Label("Inspection complete", systemImage: "checkmark.circle")
      case .failed(let message):
        VStack(alignment: .leading, spacing: 4) {
          Label("Inspection failed", systemImage: "exclamationmark.triangle")
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }

    private func languageBinding(_ language: EditorLanguage) -> Binding<Bool> {
      Binding(
        get: { model.isLanguageEnabled(language) },
        set: { model.setLanguage(language, enabled: $0) }
      )
    }

    private func dictionaryBinding(
      _ values: Binding<[EditorLanguage: String]>,
      key: EditorLanguage
    ) -> Binding<String> {
      Binding(
        get: { values.wrappedValue[key] ?? "" },
        set: { newValue in
          var updated = values.wrappedValue
          updated[key] = newValue
          values.wrappedValue = updated
        }
      )
    }

    private func detectionSummary(for language: EditorLanguage) -> String {
      guard let evidence = model.inspection?.projectInspection?.evidence(for: language) else {
        return "Detected"
      }
      var parts: [String] = []
      if evidence.sourceFileCount > 0 {
        parts.append(
          "\(evidence.sourceFileCount.formatted()) file\(evidence.sourceFileCount == 1 ? "" : "s")")
      }
      if !evidence.projectMarkers.isEmpty {
        parts.append(evidence.projectMarkers.sorted().joined(separator: ", "))
      }
      return parts.isEmpty ? "Detected" : parts.joined(separator: " · ")
    }

    private func diagnosticRow(
      title: String,
      diagnostic: EditorServiceDiagnostic?
    ) -> some View {
      HStack(alignment: .firstTextBaseline) {
        Image(systemName: statusSymbol(diagnostic?.availability))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let diagnostic {
            Text(statusText(diagnostic.availability))
              .font(.caption)
              .foregroundStyle(.secondary)
            if let suggestion = diagnostic.recoverySuggestion,
              shouldShowSuggestion(for: diagnostic)
            {
              Text(suggestion)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          } else {
            Text("Not inspected")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
    }

    private func shouldShowSuggestion(for diagnostic: EditorServiceDiagnostic) -> Bool {
      if !diagnostic.availability.isAvailable { return true }
      guard case .available(let path?) = diagnostic.availability else { return false }
      return path == "built-in lexical fallback"
    }

    private func statusSymbol(_ availability: EditorServiceAvailability?) -> String {
      switch availability {
      case .available: return "checkmark.circle.fill"
      case .disabled: return "pause.circle"
      case .missing: return "questionmark.circle"
      case .unsupported: return "nosign"
      case .invalid: return "exclamationmark.triangle.fill"
      case nil: return "circle.dashed"
      }
    }

    private func statusText(_ availability: EditorServiceAvailability) -> String {
      switch availability {
      case .available(let path): return path ?? "Available"
      case .missing: return "Not installed or not found"
      case .disabled: return "Disabled"
      case .unsupported(let reason): return reason
      case .invalid(let reason): return reason
      }
    }
  }
#endif
