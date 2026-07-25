import Foundation

/// Uses Git's own ignore engine so nested `.gitignore`, `.git/info/exclude`, and
/// the user's global excludes behave exactly as they do at the command line.
nonisolated struct GitIgnoredPathSet: Sendable {
  private let rootPath: String
  private let paths: Set<String>
  private let directoryPrefixes: Set<String>

  init?(rootURL: URL) {
    let root = rootURL.standardizedFileURL
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
      "-C", root.path, "ls-files", "--cached", "--others", "--ignored",
      "--exclude-standard", "--directory", "-z",
    ]
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("calcite-git-ignore-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
      let output = FileHandle(forWritingAtPath: outputURL.path)
    else { return nil }
    defer {
      try? output.close()
      try? FileManager.default.removeItem(at: outputURL)
    }
    let finished = DispatchSemaphore(value: 0)
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in finished.signal() }

    do {
      try process.run()
      guard finished.wait(timeout: .now() + 3) == .success else {
        if process.isRunning { process.terminate() }
        _ = finished.wait(timeout: .now() + .milliseconds(250))
        return nil
      }
      guard process.terminationStatus == 0 else { return nil }
      try output.close()
      let data = (try? Data(contentsOf: outputURL)) ?? Data()

      var paths: Set<String> = []
      var directories: Set<String> = []
      for field in data.split(separator: 0) {
        var path = String(decoding: field, as: UTF8.self)
        if path.hasSuffix("/") {
          path.removeLast()
          directories.insert(path)
        } else if !path.isEmpty {
          paths.insert(path)
        }
      }
      self.rootPath = root.path
      self.paths = paths
      self.directoryPrefixes = directories
    } catch {
      return nil
    }
  }

  func contains(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else { return false }
    let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(
      in: CharacterSet(charactersIn: "/")
    )
    guard !relative.isEmpty else { return false }
    if paths.contains(relative) || directoryPrefixes.contains(relative) { return true }
    return directoryPrefixes.contains { relative.hasPrefix($0 + "/") }
  }
}
