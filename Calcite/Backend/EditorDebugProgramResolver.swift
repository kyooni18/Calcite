import Foundation

/// Resolves only an explicitly configured launch program.
///
/// Build products are resolved by `EditorArtifactResolver` and bound to a source
/// fingerprint by `EditorBuildController`. This type deliberately does not scan
/// build directories, because a directory scan can select an executable produced
/// from an older source snapshot or a different product.
nonisolated struct EditorDebugProgramResolver {
  let workspaceURL: URL

  func resolveConfiguredPath(_ configuredPath: String) -> String? {
    let expanded = NSString(string: configuredPath).expandingTildeInPath
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expanded.isEmpty else { return nil }
    let url = URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    return url.path
  }
}
