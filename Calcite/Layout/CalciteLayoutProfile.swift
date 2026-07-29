import Foundation

/// Persisted divider geometry for one split node.
///
/// Fractions are keyed by child node identity rather than by the currently visible child index.
/// This lets a hidden fast panel recover its previous size when it becomes visible again.
nonisolated struct MainSectionSplitGeometry: Codable, Equatable, Sendable {
  var splitID: UUID
  var childFractions: [UUID: Double]
  var collapsedChildIDs: Set<UUID>

  init(
    splitID: UUID,
    childFractions: [UUID: Double] = [:],
    collapsedChildIDs: Set<UUID> = []
  ) {
    self.splitID = splitID
    self.childFractions = childFractions
    self.collapsedChildIDs = collapsedChildIDs
  }

  func resolvedFractions(
    for childIDs: [UUID],
    fallback: [Double]
  ) -> [Double] {
    guard !childIDs.isEmpty else { return [] }
    let fallback = Self.normalized(fallback, count: childIDs.count)
    let values = childIDs.enumerated().map { index, childID in
      let stored = childFractions[childID] ?? fallback[index]
      return stored.isFinite && stored > 0 ? stored : fallback[index]
    }
    return Self.normalized(values, count: childIDs.count)
  }

  mutating func update(childIDs: [UUID], fractions: [Double]) {
    guard childIDs.count == fractions.count, !childIDs.isEmpty else { return }
    let normalized = Self.normalized(fractions, count: childIDs.count)
    for (childID, fraction) in zip(childIDs, normalized) {
      childFractions[childID] = fraction
      collapsedChildIDs.remove(childID)
    }
  }

  mutating func reconcile(with childIDs: [UUID], fallback: [Double]) {
    let validIDs = Set(childIDs)
    childFractions = childFractions.filter { validIDs.contains($0.key) }
    collapsedChildIDs.formIntersection(validIDs)
    let resolved = resolvedFractions(for: childIDs, fallback: fallback)
    update(childIDs: childIDs, fractions: resolved)
  }

  private static func normalized(_ values: [Double], count: Int) -> [Double] {
    guard count > 0 else { return [] }
    let candidates: [Double]
    if values.count == count {
      candidates = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    } else {
      candidates = Array(repeating: 1, count: count)
    }
    let total = candidates.reduce(0, +)
    guard total > 0 else { return Array(repeating: 1 / Double(count), count: count) }
    return candidates.map { $0 / total }
  }
}

/// A reusable workbench arrangement. Profiles contain layout and geometry only; editor documents,
/// cursor state, focus, and debugger runtime state remain owned by their respective workspace
/// services.
nonisolated struct CalciteLayoutProfile: Codable, Equatable, Identifiable, Sendable {
  static let currentVersion = 1

  var id: UUID
  var name: String
  var version: Int
  var root: MainSectionLayoutNode
  var splitGeometry: [UUID: MainSectionSplitGeometry]
  var sidebarVisible: Bool
  var builtInPreset: MainSectionalLayoutPreset?

  init(
    id: UUID = UUID(),
    name: String,
    version: Int = Self.currentVersion,
    root: MainSectionLayoutNode,
    splitGeometry: [UUID: MainSectionSplitGeometry] = [:],
    sidebarVisible: Bool,
    builtInPreset: MainSectionalLayoutPreset? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.root = root
    self.splitGeometry = splitGeometry
    self.sidebarVisible = sidebarVisible
    self.builtInPreset = builtInPreset
  }

  var isBuiltIn: Bool { builtInPreset != nil }
}

/// Stores user-created layout profiles independently from any one workspace. The selected profile
/// and current geometry continue to be persisted by ``MainSectionalLayoutController`` per project.
@MainActor
final class CalciteLayoutProfileStore {
  private struct Payload: Codable {
    var version: Int
    var profiles: [CalciteLayoutProfile]
  }

  private let defaults: UserDefaults
  private let storageKey = "Calcite.layoutProfiles.v1"
  private let usesFileStorage: Bool
  private let storageURL = CalciteStateStorage.globalURL("layout-profiles.json")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.usesFileStorage = defaults === UserDefaults.standard
  }

  func loadCustomProfiles() -> [CalciteLayoutProfile] {
    let payload: Payload?
    if usesFileStorage {
      if let stored = CalciteStateStorage.load(Payload.self, from: storageURL) {
        payload = stored
      } else if let legacyData = defaults.data(forKey: storageKey),
        let legacy = try? JSONDecoder().decode(Payload.self, from: legacyData)
      {
        payload = legacy
        persistToFile(legacy)
        defaults.removeObject(forKey: storageKey)
      } else {
        payload = nil
      }
    } else if let data = defaults.data(forKey: storageKey) {
      payload = try? JSONDecoder().decode(Payload.self, from: data)
    } else {
      payload = nil
    }
    return sanitize(payload?.profiles ?? [])
  }

  func saveCustomProfiles(_ profiles: [CalciteLayoutProfile]) {
    let payload = Payload(
      version: CalciteLayoutProfile.currentVersion,
      profiles: sanitize(profiles)
    )
    if usesFileStorage {
      persistToFile(payload)
    } else if let data = try? JSONEncoder().encode(payload) {
      defaults.set(data, forKey: storageKey)
    }
  }

  private func persistToFile(_ payload: Payload) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? CalciteStateStorage.save(payload, to: storageURL, encoder: encoder)
  }

  private func sanitize(_ profiles: [CalciteLayoutProfile]) -> [CalciteLayoutProfile] {
    var seen: Set<UUID> = []
    return profiles.filter {
      !$0.isBuiltIn && $0.root.leafCount > 0 && seen.insert($0.id).inserted
    }
  }
}
