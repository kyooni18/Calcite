import Combine
import Foundation

@MainActor
final class FileVisibilitySettings: ObservableObject {
  @Published var showsIgnoredFiles: Bool { didSet { persist() } }
  @Published var showsBuildArtifacts: Bool { didSet { persist() } }
  @Published var showsHiddenFiles: Bool { didSet { persist() } }
  @Published var showsDSStore: Bool { didSet { persist() } }

  private let defaults: UserDefaults
  private var isLoading = true

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    showsIgnoredFiles = defaults.bool(forKey: Keys.ignored)
    showsBuildArtifacts = defaults.bool(forKey: Keys.buildArtifacts)
    showsHiddenFiles = defaults.bool(forKey: Keys.hidden)
    showsDSStore = defaults.bool(forKey: Keys.dsStore)
    isLoading = false
  }

  private func persist() {
    guard !isLoading else { return }
    defaults.set(showsIgnoredFiles, forKey: Keys.ignored)
    defaults.set(showsBuildArtifacts, forKey: Keys.buildArtifacts)
    defaults.set(showsHiddenFiles, forKey: Keys.hidden)
    defaults.set(showsDSStore, forKey: Keys.dsStore)
  }

  private enum Keys {
    static let ignored = "fileVisibilityShowsIgnoredFiles"
    static let buildArtifacts = "fileVisibilityShowsBuildArtifacts"
    static let hidden = "fileVisibilityShowsHiddenFiles"
    static let dsStore = "fileVisibilityShowsDSStore"
  }
}
