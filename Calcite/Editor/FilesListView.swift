import AppKit
import Combine
import Foundation
import SwiftUI

nonisolated struct ProjectFileNode: Identifiable, Hashable, Sendable {
  let url: URL
  let children: [ProjectFileNode]?

  var id: URL { url }
  var isDirectory: Bool { children != nil }
  var containingDirectory: URL { isDirectory ? url : url.deletingLastPathComponent() }
}

@MainActor
final class ProjectFileTreeModel: ObservableObject {
  @Published private(set) var roots: [ProjectFileNode] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var warningMessage: String?
  @Published private(set) var isLoading = false
  @Published private(set) var revision: UInt64 = 0

  let rootURL: URL
  private var loadTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?
  private var eventReloadTask: Task<Void, Never>?
  private var fileSystemMonitor: ProjectFileSystemMonitor?
  private var pendingFileSystemChanges = ProjectFileChangeBatch()
  private var loadGeneration: UInt64 = 0
  private var structureFingerprint: Int?
  private var projectContextFingerprint: Int?
  private var includesIgnoredFiles = false
  private var includesBuildArtifacts = false
  private var includesHiddenFiles = false
  private var includesDSStore = false

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  isolated deinit {
    loadTask?.cancel()
    monitorTask?.cancel()
    eventReloadTask?.cancel()
    fileSystemMonitor?.stop()
  }

  func start() {
    reload()
    if fileSystemMonitor == nil {
      fileSystemMonitor = ProjectFileSystemMonitor(rootURL: rootURL) { [weak self] batch in
        Task { @MainActor [weak self] in self?.scheduleEventReload(batch) }
      }
    }
    guard monitorTask == nil else { return }
    // A slow fallback catches rare dropped/coalesced events without rescanning every few seconds.
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard let self, !Task.isCancelled else { return }
        await self.refreshIfChanged()
      }
    }
  }

  func stop() {
    monitorTask?.cancel()
    monitorTask = nil
    eventReloadTask?.cancel()
    eventReloadTask = nil
    fileSystemMonitor?.stop()
    fileSystemMonitor = nil
    pendingFileSystemChanges = ProjectFileChangeBatch()
  }

  private func scheduleEventReload(_ batch: ProjectFileChangeBatch) {
    pendingFileSystemChanges.merge(batch)
    eventReloadTask?.cancel()
    eventReloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(220))
      guard let self, !Task.isCancelled else { return }
      let changes = self.pendingFileSystemChanges
      self.pendingFileSystemChanges = ProjectFileChangeBatch()
      guard self.requiresTreeRefresh(for: changes) else { return }
      await self.refreshIfChanged()
    }
  }

  private func requiresTreeRefresh(for batch: ProjectFileChangeBatch) -> Bool {
    if batch.requiresFullRescan || batch.rootWasMovedOrDeleted { return true }
    let paths = batch.changedPaths.union(batch.removedPaths).union(batch.renamedPaths)
    guard !paths.isEmpty else { return false }
    return paths.contains { !isIgnoredEventPath($0) }
  }

  private func isIgnoredEventPath(_ url: URL) -> Bool {
    let rootPath = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
    let relativePath = path.dropFirst(rootPath.count)
    let components = relativePath.split(separator: "/").map(String.init)
    if components.contains(".git") { return true }
    if !includesBuildArtifacts,
      components.contains(where: {
        $0 == ".build" || $0 == "DerivedData" || $0 == "node_modules"
      })
    {
      return true
    }
    if !includesDSStore, url.lastPathComponent == ".DS_Store" { return true }
    return false
  }

  func setIncludesIgnoredFiles(_ includesIgnoredFiles: Bool) {
    guard self.includesIgnoredFiles != includesIgnoredFiles else { return }
    self.includesIgnoredFiles = includesIgnoredFiles
    reload()
  }

  func setIncludesBuildArtifacts(_ includesBuildArtifacts: Bool) {
    guard self.includesBuildArtifacts != includesBuildArtifacts else { return }
    self.includesBuildArtifacts = includesBuildArtifacts
    reload()
  }

  func setIncludesHiddenFiles(_ includesHiddenFiles: Bool) {
    guard self.includesHiddenFiles != includesHiddenFiles else { return }
    self.includesHiddenFiles = includesHiddenFiles
    reload()
  }

  func setIncludesDSStore(_ includesDSStore: Bool) {
    guard self.includesDSStore != includesDSStore else { return }
    self.includesDSStore = includesDSStore
    reload()
  }

  func reload() {
    loadTask?.cancel()
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    errorMessage = nil
    let root = rootURL
    let includesIgnoredFiles = includesIgnoredFiles
    let includesBuildArtifacts = includesBuildArtifacts
    let includesHiddenFiles = includesHiddenFiles
    let includesDSStore = includesDSStore
    loadTask = Task { [weak self] in
      let result = await Self.scan(
        root,
        includesIgnoredFiles: includesIgnoredFiles,
        includesBuildArtifacts: includesBuildArtifacts,
        includesHiddenFiles: includesHiddenFiles,
        includesDSStore: includesDSStore
      )
      guard let self else { return }
      // A cancelled scan may finish after its replacement has started. Only the
      // current generation is allowed to settle the loading state.
      guard self.loadGeneration == generation else { return }
      defer {
        self.isLoading = false
        self.loadTask = nil
      }
      guard !Task.isCancelled else { return }
      self.apply(result, replaceUnchanged: true)
    }
  }

  private func refreshIfChanged() async {
    guard loadTask == nil else { return }
    let result = await Self.scan(
      rootURL,
      includesIgnoredFiles: includesIgnoredFiles,
      includesBuildArtifacts: includesBuildArtifacts,
      includesHiddenFiles: includesHiddenFiles,
      includesDSStore: includesDSStore
    )
    guard !Task.isCancelled else { return }
    apply(result, replaceUnchanged: false)
  }

  private func apply(_ result: ProjectFileLoadResult, replaceUnchanged: Bool) {
    switch result {
    case .success(let scan):
      let structureChanged = structureFingerprint != scan.structureFingerprint
      let projectContextChanged = projectContextFingerprint != scan.projectContextFingerprint
      if replaceUnchanged || structureChanged {
        roots = scan.nodes
      }
      structureFingerprint = scan.structureFingerprint
      projectContextFingerprint = scan.projectContextFingerprint
      if structureChanged || projectContextChanged { revision &+= 1 }
      errorMessage = nil
      var warnings: [String] = []
      if scan.wasTruncated {
        warnings.append("Limited to \(ProjectFileScanner.maximumNodeCount.formatted()) items.")
      }
      if scan.skippedDirectoryCount > 0 {
        warnings.append("Skipped \(scan.skippedDirectoryCount.formatted()) unreadable folders.")
      }
      warningMessage = warnings.isEmpty ? nil : warnings.joined(separator: " ")
    case .failure(let message):
      if roots.isEmpty { errorMessage = message }
    case .cancelled:
      break
    }
  }

  nonisolated private static func scan(
    _ root: URL,
    includesIgnoredFiles: Bool,
    includesBuildArtifacts: Bool,
    includesHiddenFiles: Bool,
    includesDSStore: Bool
  ) async -> ProjectFileLoadResult {
    let worker = Task.detached(priority: .utility) {
      do {
        return ProjectFileLoadResult.success(
          try ProjectFileScanner.scan(
            rootURL: root,
            includeIgnoredFiles: includesIgnoredFiles,
            includeBuildArtifacts: includesBuildArtifacts,
            includeHiddenFiles: includesHiddenFiles,
            includeDSStore: includesDSStore,
            respectGitIgnore: !includesIgnoredFiles
          )
        )
      } catch is CancellationError {
        return ProjectFileLoadResult.cancelled
      } catch {
        return ProjectFileLoadResult.failure(error.localizedDescription)
      }
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}

struct FilesListView: View {
  @StateObject private var model: ProjectFileTreeModel
  @Binding private var selectedURL: URL?
  @State private var prompt: FileTreePrompt?
  @State private var promptValue = ""
  @State private var deletionTarget: ProjectFileNode?
  @ObservedObject private var visibility: FileVisibilitySettings

  let onOpen: (URL) -> Void
  let onCreateFile: (URL, String) async -> Bool
  let onCreateDirectory: (URL, String) async -> Bool
  let onRename: (URL, String) async -> Bool
  let onDuplicate: (URL) async -> Bool
  let onDelete: (URL) async -> Bool
  let hasUnsavedChanges: (URL) -> Bool
  let onTreeChange: () -> Void

  init(
    rootURL: URL,
    visibility: FileVisibilitySettings,
    selectedURL: Binding<URL?>,
    onOpen: @escaping (URL) -> Void,
    onCreateFile: @escaping (URL, String) async -> Bool,
    onCreateDirectory: @escaping (URL, String) async -> Bool,
    onRename: @escaping (URL, String) async -> Bool,
    onDuplicate: @escaping (URL) async -> Bool,
    onDelete: @escaping (URL) async -> Bool,
    hasUnsavedChanges: @escaping (URL) -> Bool,
    onTreeChange: @escaping () -> Void = {}
  ) {
    _model = StateObject(wrappedValue: ProjectFileTreeModel(rootURL: rootURL))
    _visibility = ObservedObject(wrappedValue: visibility)
    _selectedURL = selectedURL
    self.onOpen = onOpen
    self.onCreateFile = onCreateFile
    self.onCreateDirectory = onCreateDirectory
    self.onRename = onRename
    self.onDuplicate = onDuplicate
    self.onDelete = onDelete
    self.hasUnsavedChanges = hasUnsavedChanges
    self.onTreeChange = onTreeChange
  }

  var body: some View {
    Group {
      if model.isLoading, model.roots.isEmpty {
        VStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading files").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = model.errorMessage, model.roots.isEmpty {
        ContentUnavailableView(
          "Files Unavailable",
          systemImage: "folder.badge.questionmark",
          description: Text(error)
        )
      } else {
        VStack(spacing: 0) {
          List(model.roots, children: \.children, selection: $selectedURL) { node in
            ProjectFileRow(node: node)
              .tag(node.url)
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { open(node) }
              .contextMenu { contextMenu(for: node) }
          }
          .listStyle(.sidebar)
          .contextMenu { rootContextMenu }
          if let warning = model.warningMessage {
            Text(warning)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .background(.bar)
          }
          HStack(spacing: 4) {
            Menu {
              Toggle("Hidden Files", systemImage: "dot.circle", isOn: $visibility.showsHiddenFiles)
              Toggle(".DS_Store", systemImage: "internaldrive", isOn: $visibility.showsDSStore)
              Toggle(
                "Git-Ignored Files",
                systemImage: "eye.slash",
                isOn: $visibility.showsIgnoredFiles
              )
              Toggle(
                "Build Artifacts",
                systemImage: "shippingbox",
                isOn: $visibility.showsBuildArtifacts
              )
            } label: {
              Image(
                systemName: visibility.showsHiddenFiles || visibility.showsDSStore
                  || visibility.showsIgnoredFiles
                  || visibility.showsBuildArtifacts ? "eye" : "eye.slash"
              )
            }
            .menuStyle(.borderlessButton)
            .help("File visibility")
            .accessibilityLabel("File visibility")

            Spacer()

            Button {
              model.reload()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .help("Refresh file tree")
            .accessibilityLabel("Refresh file tree")
            .buttonStyle(.plain)
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 9)
          .padding(.vertical, 7)
          .background(.bar)
        }
      }
    }
    .task { model.start() }
    .onAppear {
      model.setIncludesIgnoredFiles(visibility.showsIgnoredFiles)
      model.setIncludesBuildArtifacts(visibility.showsBuildArtifacts)
      model.setIncludesHiddenFiles(visibility.showsHiddenFiles)
      model.setIncludesDSStore(visibility.showsDSStore)
    }
    .onChange(of: visibility.showsIgnoredFiles) { _, newValue in
      model.setIncludesIgnoredFiles(newValue)
    }
    .onChange(of: visibility.showsBuildArtifacts) { _, newValue in
      model.setIncludesBuildArtifacts(newValue)
    }
    .onChange(of: visibility.showsHiddenFiles) { _, newValue in
      model.setIncludesHiddenFiles(newValue)
    }
    .onChange(of: visibility.showsDSStore) { _, newValue in
      model.setIncludesDSStore(newValue)
    }
    .onDisappear { model.stop() }
    .onChange(of: model.revision) { _, _ in onTreeChange() }
    .alert(prompt?.title ?? "File", isPresented: promptBinding) {
      TextField(prompt?.placeholder ?? "Name", text: $promptValue)
      Button("Cancel", role: .cancel) { clearPrompt() }
      Button(prompt?.actionTitle ?? "Create") { performPrompt() }
        .disabled(promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text(prompt?.message ?? "")
    }
    .confirmationDialog(
      "Delete this item?",
      isPresented: deletionBinding,
      titleVisibility: .visible
    ) {
      Button(deletionButtonTitle, role: .destructive) { performDeletion() }
      Button("Cancel", role: .cancel) { deletionTarget = nil }
    } message: {
      Text(deletionMessage)
    }
  }

  private var deletionButtonTitle: String {
    guard let target = deletionTarget, hasUnsavedChanges(target.url) else { return "Delete" }
    return "Delete and Discard Changes"
  }

  private var deletionMessage: String {
    guard let target = deletionTarget else { return "" }
    if hasUnsavedChanges(target.url) {
      return
        "\(target.url.lastPathComponent) contains open files with unsaved changes. Deleting it will permanently discard those changes."
    }
    return target.url.lastPathComponent
  }

  @ViewBuilder
  private var rootContextMenu: some View {
    Button("New File…", systemImage: "doc.badge.plus") {
      beginPrompt(.createFile(in: model.rootURL))
    }
    Button("New Folder…", systemImage: "folder.badge.plus") {
      beginPrompt(.createDirectory(in: model.rootURL))
    }
    Divider()
    Button("Reveal Project in Finder", systemImage: "finder") {
      NSWorkspace.shared.activateFileViewerSelecting([model.rootURL])
    }
    Button("Copy Project Path", systemImage: "doc.on.doc") {
      copyPath(model.rootURL)
    }
    Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
  }

  @ViewBuilder
  private func contextMenu(for node: ProjectFileNode) -> some View {
    if !node.isDirectory {
      Button("Open", systemImage: "doc.text") { open(node) }
      Button("Duplicate", systemImage: "plus.square.on.square") {
        Task {
          if await onDuplicate(node.url) { model.reload() }
        }
      }
    }

    Button("New File…", systemImage: "doc.badge.plus") {
      beginPrompt(.createFile(in: node.containingDirectory))
    }
    Button("New Folder…", systemImage: "folder.badge.plus") {
      beginPrompt(.createDirectory(in: node.containingDirectory))
    }

    Divider()

    Button("Rename…", systemImage: "pencil") {
      beginPrompt(.rename(node.url))
    }
    Button("Delete", systemImage: "trash", role: .destructive) {
      deletionTarget = node
    }

    Divider()

    Button("Reveal in Finder", systemImage: "finder") {
      NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
    Button("Copy Path", systemImage: "doc.on.doc") {
      copyPath(node.url)
    }
    Button("Refresh", systemImage: "arrow.clockwise") { model.reload() }
  }

  private func copyPath(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.path, forType: .string)
  }

  private var promptBinding: Binding<Bool> {
    Binding(
      get: { prompt != nil },
      set: { if !$0 { clearPrompt() } }
    )
  }

  private var deletionBinding: Binding<Bool> {
    Binding(
      get: { deletionTarget != nil },
      set: { if !$0 { deletionTarget = nil } }
    )
  }

  private func open(_ node: ProjectFileNode) {
    guard !node.isDirectory else { return }
    onOpen(node.url)
  }

  private func beginPrompt(_ value: FileTreePrompt) {
    prompt = value
    promptValue = value.initialValue
  }

  private func clearPrompt() {
    prompt = nil
    promptValue = ""
  }

  private func performPrompt() {
    guard let prompt else { return }
    let value = promptValue
    clearPrompt()
    Task {
      let succeeded: Bool
      switch prompt.kind {
      case .createFile(let directory):
        succeeded = await onCreateFile(directory, value)
      case .createDirectory(let directory):
        succeeded = await onCreateDirectory(directory, value)
      case .rename(let url):
        succeeded = await onRename(url, value)
        if succeeded, selectedURL == url { selectedURL = nil }
      }
      if succeeded { model.reload() }
    }
  }

  private func performDeletion() {
    guard let target = deletionTarget else { return }
    deletionTarget = nil
    Task {
      if await onDelete(target.url) {
        if selectedURL == target.url { selectedURL = nil }
        model.reload()
      }
    }
  }
}

private struct ProjectFileRow: View {
  let node: ProjectFileNode

  var body: some View {
    HStack(spacing: 6) {
      if node.isDirectory {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
      } else {
        CIcon(code: fileIconCode(forFileName: node.url.lastPathComponent), size: 13)
      }
      Text(node.url.lastPathComponent)
        .lineLimit(1)
    }
  }
}

private struct FileTreePrompt {
  enum Kind {
    case createFile(URL)
    case createDirectory(URL)
    case rename(URL)
  }

  let kind: Kind

  static func createFile(in directory: URL) -> Self { .init(kind: .createFile(directory)) }
  static func createDirectory(in directory: URL) -> Self {
    .init(kind: .createDirectory(directory))
  }
  static func rename(_ url: URL) -> Self { .init(kind: .rename(url)) }

  var title: String {
    switch kind {
    case .createFile: return "New File"
    case .createDirectory: return "New Folder"
    case .rename: return "Rename"
    }
  }

  var actionTitle: String {
    switch kind {
    case .rename: return "Rename"
    case .createFile, .createDirectory: return "Create"
    }
  }

  var placeholder: String {
    switch kind {
    case .createFile: return "File name"
    case .createDirectory: return "Folder name"
    case .rename: return "New name"
    }
  }

  var message: String {
    switch kind {
    case .createFile(let directory), .createDirectory(let directory):
      return directory.path
    case .rename(let url):
      return url.lastPathComponent
    }
  }

  var initialValue: String {
    switch kind {
    case .rename(let url): return url.lastPathComponent
    case .createFile, .createDirectory: return ""
    }
  }
}

nonisolated struct ProjectFileScanResult: Sendable {
  var nodes: [ProjectFileNode]
  var wasTruncated: Bool
  var skippedDirectoryCount: Int
  var structureFingerprint: Int
  var projectContextFingerprint: Int

  var files: [URL] {
    var result: [URL] = []
    var stack = Array(nodes.reversed())
    while let node = stack.popLast() {
      if let children = node.children {
        stack.append(contentsOf: children.reversed())
      } else {
        result.append(node.url)
      }
    }
    return result
  }
}

nonisolated private enum ProjectFileLoadResult: Sendable {
  case success(ProjectFileScanResult)
  case failure(String)
  case cancelled
}

nonisolated struct ProjectFileScanner {
  static let maximumNodeCount = 20_000
  private static let maximumDepth = 32
  private static let alwaysSkippedNames: Set<String> = [".git", "__MACOSX"]
  /// Project configuration dotfiles remain discoverable even when the general hidden-file
  /// preference is disabled. These files frequently control builds, formatting and language
  /// servers, so silently omitting them makes the project tree misleading.
  private static let alwaysVisibleHiddenNames: Set<String> = [
    ".clang-format", ".clang-tidy", ".clangd", ".editorconfig", ".env.example",
    ".gitattributes", ".gitignore", ".github", ".cargo", ".npmrc", ".nvmrc",
    ".python-version", ".rustfmt.toml", ".swift-format", ".swiftformat",
    ".swiftlint.yml", ".tool-versions", ".vscode",
  ]
  private static let buildArtifactNames: Set<String> = [
    ".build", ".swiftpm", "DerivedData", "target", "build", "dist", ".gradle",
    "zig-cache", ".zig-cache", "coverage", ".next", "out",
  ]
  private static let fallbackIgnoredNames: Set<String> = [
    "node_modules", ".idea", "Pods", "vendor", "Vendor", "venv", ".venv", ".cache",
  ]
  private static let projectContextDirectoryNames: Set<String> = [
    ".venv", "venv", ".env", "env", "conda-meta", ".calcite",
  ]
  private static let projectContextNames: Set<String> = [
    "Package.swift", "Package.resolved", "Cargo.toml", "Cargo.lock", "go.mod", "go.sum",
    "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock",
    "bun.lockb", "build.gradle", "build.gradle.kts", "settings.gradle",
    "settings.gradle.kts", "gradle.properties", "pom.xml", "build.zig", "build.zig.zon",
    "CMakeLists.txt", "Makefile", "makefile", "pyproject.toml", "Pipfile",
    "poetry.lock", "requirements.txt", "environment.yml", "environment.yaml",
    "conda-lock.yml", "pyvenv.cfg", ".python-version", ".tool-versions", ".clangd",
    "compile_commands.json", "tsconfig.json", "jsconfig.json", "tasks.json",
  ]

  private var remainingNodes = maximumNodeCount
  private var wasTruncated = false
  private var skippedDirectoryCount = 0
  private var structureFingerprintHasher = Hasher()
  private var projectContextFingerprintHasher = Hasher()

  static func scan(
    rootURL: URL,
    includeIgnoredFiles: Bool = false,
    includeBuildArtifacts: Bool = false,
    includeHiddenFiles: Bool = false,
    includeDSStore: Bool = false,
    respectGitIgnore: Bool = true
  ) throws -> ProjectFileScanResult {
    var scanner = ProjectFileScanner(
      includeIgnoredFiles: includeIgnoredFiles,
      includeBuildArtifacts: includeBuildArtifacts,
      includeHiddenFiles: includeHiddenFiles,
      includeDSStore: includeDSStore,
      ignoredPaths: respectGitIgnore && !includeIgnoredFiles
        ? GitIgnoredPathSet(rootURL: rootURL) : nil
    )
    let nodes = try scanner.children(of: rootURL.standardizedFileURL, depth: 0)
    return ProjectFileScanResult(
      nodes: nodes,
      wasTruncated: scanner.wasTruncated,
      skippedDirectoryCount: scanner.skippedDirectoryCount,
      structureFingerprint: scanner.structureFingerprintHasher.finalize(),
      projectContextFingerprint: scanner.projectContextFingerprintHasher.finalize()
    )
  }

  private let includeIgnoredFiles: Bool
  private let includeBuildArtifacts: Bool
  private let includeHiddenFiles: Bool
  private let includeDSStore: Bool
  private let ignoredPaths: GitIgnoredPathSet?

  private mutating func children(
    of directory: URL,
    depth: Int,
    insideBuildArtifact: Bool = false
  ) throws -> [ProjectFileNode] {
    try Task.checkCancellation()
    guard depth <= Self.maximumDepth else {
      wasTruncated = true
      return []
    }
    guard remainingNodes > 0 else {
      wasTruncated = true
      return []
    }

    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
      .contentModificationDateKey, .fileSizeKey,
    ]
    let values = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsPackageDescendants]
    )

    var result: [ProjectFileNode] = []
    result.reserveCapacity(min(values.count, remainingNodes))
    for url in values {
      try Task.checkCancellation()
      guard remainingNodes > 0 else {
        wasTruncated = true
        break
      }
      let resource = try url.resourceValues(forKeys: keys)
      guard resource.isSymbolicLink != true else { continue }
      let itemName = url.lastPathComponent
      guard !Self.alwaysSkippedNames.contains(itemName) else { continue }

      let standardizedPath = url.standardizedFileURL.path
      let isDirectory = resource.isDirectory == true
      let tracksProjectContext =
        Self.projectContextNames.contains(itemName)
        || (isDirectory && Self.projectContextDirectoryNames.contains(itemName))
        || standardizedPath.contains("/.calcite/")
      if tracksProjectContext {
        // Environment and build markers affect execution even when their directory is hidden
        // from the file tree. Keep them in a separate fingerprint so creating `.venv`, for
        // example, reconfigures build, LSP and terminal environments without exposing it.
        projectContextFingerprintHasher.combine(standardizedPath)
        projectContextFingerprintHasher.combine(isDirectory)
        projectContextFingerprintHasher.combine(
          resource.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        )
        projectContextFingerprintHasher.combine(resource.fileSize ?? 0)
      }

      let isBuildArtifact = insideBuildArtifact || Self.buildArtifactNames.contains(itemName)
      if itemName == ".DS_Store", !includeDSStore { continue }
      guard
        includeHiddenFiles || resource.isHidden != true || itemName == ".DS_Store"
          || Self.alwaysVisibleHiddenNames.contains(itemName)
          || (includeBuildArtifacts && isBuildArtifact)
      else { continue }
      if isBuildArtifact, !includeBuildArtifacts { continue }
      let isIgnored =
        !isBuildArtifact
        && (ignoredPaths?.contains(url)
          ?? (!includeIgnoredFiles && Self.fallbackIgnoredNames.contains(itemName)))
      if isIgnored, !includeIgnoredFiles { continue }

      structureFingerprintHasher.combine(standardizedPath)
      structureFingerprintHasher.combine(isDirectory)

      if resource.isDirectory == true {
        remainingNodes -= 1
        let childNodes: [ProjectFileNode]
        do {
          childNodes = try children(
            of: url,
            depth: depth + 1,
            insideBuildArtifact: isBuildArtifact
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          skippedDirectoryCount += 1
          childNodes = []
        }
        result.append(
          ProjectFileNode(
            url: url.standardizedFileURL,
            children: childNodes
          )
        )
      } else if resource.isRegularFile == true {
        remainingNodes -= 1
        result.append(ProjectFileNode(url: url.standardizedFileURL, children: nil))
      }
    }
    return result.sorted(by: Self.nodeSort)
  }

  private static func nodeSort(_ lhs: ProjectFileNode, _ rhs: ProjectFileNode) -> Bool {
    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
    return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
      == .orderedAscending
  }
}
