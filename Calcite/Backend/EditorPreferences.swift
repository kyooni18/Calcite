import EditorServices
import Foundation

struct EditorServiceSelectionPreferences: Codable, Sendable {
  var languages: EditorLanguageSelection
  var inspection: EditorProjectInspectionConfiguration
  var features: EditorFeatureSelection
  var requirement: EditorServiceRequirementPolicy
}

struct EditorServicePathPreferences: Codable, Sendable {
  var languageServers: [EditorLanguage: String]
  var debugAdapters: [EditorLanguage: String]
  var syntaxLibraries: [EditorLanguage: String]
}

struct EditorServicePreferences: Codable, Sendable {
  var selection: EditorServiceSelectionPreferences
  var paths: EditorServicePathPreferences
}

enum EditorServicePreferencesStore {
  static func load(
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) -> EditorServicePreferences? {
    guard let data = defaults.data(forKey: key(for: workspaceURL)) else { return nil }
    return try? JSONDecoder().decode(EditorServicePreferences.self, from: data)
  }

  static func save(
    configuration: EditorServicesConfiguration,
    defaults: UserDefaults = .standard
  ) {
    let preferences = EditorServicePreferences(
      selection: .init(
        languages: configuration.languageSelection,
        inspection: configuration.projectInspectionConfiguration,
        features: configuration.features,
        requirement: configuration.requirementPolicy
      ),
      paths: .init(
        languageServers: configuration.overrides.languageServerExecutables,
        debugAdapters: configuration.overrides.debugAdapterExecutables,
        syntaxLibraries: configuration.overrides.syntaxLibraries.mapValues(\.libraryURL.path)
      )
    )
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: key(for: configuration.workspaceURL))
  }

  static func apply(
    _ preferences: EditorServicePreferences?,
    to configuration: EditorServicesConfiguration
  ) -> EditorServicesConfiguration {
    guard let preferences else { return configuration }
    var value = configuration
    value.languageSelection = preferences.selection.languages
    value.projectInspectionConfiguration = preferences.selection.inspection
    value.features = preferences.selection.features
    value.requirementPolicy = preferences.selection.requirement
    value.overrides.languageServerExecutables = preferences.paths.languageServers
    value.overrides.debugAdapterExecutables = preferences.paths.debugAdapters
    value.overrides.syntaxLibraries = preferences.paths.syntaxLibraries.mapValues {
      EditorSyntaxLibraryConfiguration(
        libraryURL: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
      )
    }
    return value
  }

  private static func key(for workspaceURL: URL) -> String {
    let encoded = Data(workspaceURL.standardizedFileURL.path.utf8).base64EncodedString()
    return "editor.services.preferences.\(encoded)"
  }
}

enum EditorDebugPreferencesStore {
  static func load(
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) -> EditorDebugConfiguration? {
    guard let data = defaults.data(forKey: key(for: workspaceURL)) else { return nil }
    return try? JSONDecoder().decode(EditorDebugConfiguration.self, from: data)
  }

  static func save(
    _ configuration: EditorDebugConfiguration,
    workspaceURL: URL,
    defaults: UserDefaults = .standard
  ) {
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    defaults.set(data, forKey: key(for: workspaceURL))
  }

  private static func key(for workspaceURL: URL) -> String {
    let encoded = Data(workspaceURL.standardizedFileURL.path.utf8).base64EncodedString()
    return "editor.debug.configuration.\(encoded)"
  }
}
