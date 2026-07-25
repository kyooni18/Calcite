import AppKit
import SwiftUI

struct CalciteCommandPaletteSurface: View {
  enum Mode: Sendable, Equatable {
    case all
    case files
    case commands

    var placeholder: String {
      switch self {
      case .all: "Search files or run a command"
      case .files: "Search files"
      case .commands: "Run command"
      }
    }
  }

  enum KeyboardCommand: Sendable, Equatable {
    case moveUp
    case moveDown
    case submit
    case dismiss
  }

  struct KeyboardEvent: Equatable {
    let id = UUID()
    let command: KeyboardCommand
  }

  struct Action: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let category: String
    let keywords: [String]
    let perform: () -> Void

    init(
      id: String,
      title: String,
      systemImage: String,
      category: String = "General",
      keywords: [String] = [],
      perform: @escaping () -> Void
    ) {
      self.id = id
      self.title = title
      self.systemImage = systemImage
      self.category = category
      self.keywords = keywords
      self.perform = perform
    }

    var searchableText: String {
      ([title, category] + keywords).joined(separator: " ")
    }
  }

  private enum Selection: Hashable {
    case file(URL)
    case action(String)
  }

  let workspaceURL: URL
  let mode: Mode
  let actions: [Action]
  let openFile: (URL) -> Void
  let dismiss: () -> Void
  @Binding var query: String
  @Binding var includeIgnoredFiles: Bool
  @Binding var includeBuildArtifacts: Bool
  @Binding var includeHiddenFiles: Bool
  @Binding var includeDSStore: Bool
  var showsSearchHeader = true
  var keyboardEvent: KeyboardEvent?

  @State private var files: [URL] = []
  @State private var packageRoots: [URL] = []
  @State private var selectedPackage: URL?
  @State private var packageFiles: [URL] = []
  @State private var rankedFiles: [URL] = []
  @State private var selection: Selection?
  @State private var fileSearchTask: Task<Void, Never>?
  @State private var packageScanTask: Task<Void, Never>?
  @State private var isScanningProject = false
  @State private var isScanningPackage = false
  @State private var isRanking = false
  @State private var projectScanGeneration = 0
  @FocusState private var searchIsFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      if showsSearchHeader {
        searchHeader
        Divider()
      } else if mode != .commands {
        compactOptionsHeader
        Divider()
      }
      results
      footer
    }
    .background { CalciteBackground() }
    .task(
      id: SearchOptions(
        includeIgnoredFiles: includeIgnoredFiles,
        includeBuildArtifacts: includeBuildArtifacts,
        includeHiddenFiles: includeHiddenFiles,
        includeDSStore: includeDSStore)
    ) {
      await reloadProjectFiles()
    }
    .onAppear {
      if showsSearchHeader { searchIsFocused = true }
      updateSelection()
      if let keyboardEvent { handleKeyboardEvent(keyboardEvent) }
    }
    .onChange(of: keyboardEvent) { _, event in
      guard let event else { return }
      handleKeyboardEvent(event)
    }
    .onChange(of: query) { _, _ in
      scheduleFileSearch()
      updateSelection()
    }
    .onChange(of: rankedFiles) { _, _ in updateSelection() }
    .onChange(of: filteredActionIDs) { _, _ in updateSelection() }
    .onKeyPress(.downArrow) {
      moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      moveSelection(by: -1)
      return .handled
    }
    .onKeyPress(.tab) {
      moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .onDisappear {
      fileSearchTask?.cancel()
      packageScanTask?.cancel()
    }
  }

  private var searchHeader: some View {
    HStack(spacing: 9) {
      Image(systemName: mode == .commands || isCommandQuery ? "command" : "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(mode.placeholder, text: $query)
        .textFieldStyle(.plain)
        .focused($searchIsFocused)
        .onSubmit { performSelectedResult() }

      if mode != .commands {
        packageSearchMenu
        searchFiltersMenu
      }

      Button("Close", systemImage: "xmark") { dismiss() }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 13)
    .frame(height: 48)
  }

  private var compactOptionsHeader: some View {
    HStack(spacing: 8) {
      packageSearchMenu
      searchFiltersMenu
      if activeSearchFilterCount > 0 {
        Text("\(activeSearchFilterCount) filters")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(isCommandQuery ? "Commands" : mode == .files ? "Files" : "Files and Commands")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
  }

  private var activeSearchFilterCount: Int {
    [includeIgnoredFiles, includeBuildArtifacts, includeHiddenFiles, includeDSStore]
      .filter { $0 }
      .count
  }

  private var searchFiltersMenu: some View {
    Menu {
      Section("Project Files") {
        Toggle("Include Ignored Files", isOn: $includeIgnoredFiles)
        Toggle("Include Hidden Files", isOn: $includeHiddenFiles)
      }

      Section("Generated and System Files") {
        Toggle("Include Build Artifacts", isOn: $includeBuildArtifacts)
        Toggle("Include .DS_Store", isOn: $includeDSStore)
      }

      Divider()

      Button("Use Recommended Filters", systemImage: "arrow.counterclockwise") {
        includeIgnoredFiles = false
        includeBuildArtifacts = false
        includeHiddenFiles = false
        includeDSStore = false
      }
      .disabled(activeSearchFilterCount == 0)
    } label: {
      Image(
        systemName: activeSearchFilterCount == 0
          ? "line.3.horizontal.decrease.circle"
          : "line.3.horizontal.decrease.circle.fill"
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Search filters")
    .help(
      activeSearchFilterCount == 0
        ? "Search Filters"
        : "Search Filters (\(activeSearchFilterCount) enabled)"
    )
  }

  private var results: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          if mode == .all {
            if !isCommandQuery, !rankedFiles.isEmpty {
              sectionTitle("Files")
              fileResults
            }
            if !filteredActions.isEmpty {
              sectionTitle("Commands")
              commandResults
            }
          } else if mode == .commands {
            commandResults
          } else {
            fileResults
          }

          if visibleSelections.isEmpty, !isBusy {
            ContentUnavailableView(
              emptyTitle,
              systemImage: mode == .commands || isCommandQuery ? "command" : "magnifyingglass"
            )
            .frame(maxWidth: .infinity, minHeight: 280)
          }
        }
        .padding(8)
      }
      .scrollIndicators(.automatic)
      .onChange(of: selection) { _, next in
        guard let next else { return }
        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(next, anchor: .center) }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if isBusy {
        ProgressView().controlSize(.mini)
        Text(busyTitle)
      } else if let selectedPackage {
        Image(systemName: "shippingbox")
        Text(selectedPackage.lastPathComponent)
      } else {
        Text("↑↓ Select")
        Text("↩ Open")
        Text("esc Close")
      }
      Spacer()
      Text("\(visibleSelections.count) results")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 28)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.top, 5)
      .padding(.bottom, 2)
  }

  private var filteredActions: [Action] {
    let value = commandQuery
    guard !value.isEmpty else { return actions }
    return
      actions
      .filter { Self.fuzzyMatch($0.searchableText, query: value) }
      .sorted {
        let lhs = max(
          Self.matchScore($0.title, query: value),
          Self.matchScore($0.searchableText, query: value)
        )
        let rhs = max(
          Self.matchScore($1.title, query: value),
          Self.matchScore($1.searchableText, query: value)
        )
        if lhs != rhs { return lhs > rhs }
        if $0.category != $1.category {
          return $0.category.localizedStandardCompare($1.category) == .orderedAscending
        }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
  }

  private var filteredActionIDs: [String] { filteredActions.map(\.id) }
  private var isCommandQuery: Bool { mode == .all && query.hasPrefix("/") }
  private var commandQuery: String {
    isCommandQuery ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query
  }

  private var visibleSelections: [Selection] {
    switch mode {
    case .all:
      if isCommandQuery { return filteredActions.map { .action($0.id) } }
      return rankedFiles.map(Selection.file) + filteredActions.map { .action($0.id) }
    case .files:
      return rankedFiles.map(Selection.file)
    case .commands:
      return filteredActions.map { .action($0.id) }
    }
  }

  private var isBusy: Bool { isScanningProject || isScanningPackage || isRanking }
  private var busyTitle: String {
    if isScanningProject { return "Indexing project" }
    if isScanningPackage { return "Indexing package" }
    return "Ranking results"
  }
  private var emptyTitle: String {
    mode == .commands || isCommandQuery ? "No Commands" : files.isEmpty ? "No Files" : "No Results"
  }

  private func handleKeyboardEvent(_ event: KeyboardEvent) {
    switch event.command {
    case .moveUp:
      moveSelection(by: -1)
    case .moveDown:
      moveSelection(by: 1)
    case .submit:
      performSelectedResult()
    case .dismiss:
      dismiss()
    }
  }

  private func performSelectedResult() {
    let target = selection ?? visibleSelections.first
    guard let target else { return }
    switch target {
    case .file(let url): openFile(url)
    case .action(let id): actions.first(where: { $0.id == id })?.perform()
    }
    dismiss()
  }

  private func moveSelection(by offset: Int) {
    let values = visibleSelections
    guard !values.isEmpty else {
      selection = nil
      return
    }
    guard let selection, let index = values.firstIndex(of: selection) else {
      self.selection = offset < 0 ? values.last : values.first
      return
    }
    self.selection = values[(index + offset + values.count) % values.count]
  }

  private func updateSelection() {
    let values = visibleSelections
    if let selection, values.contains(selection) { return }
    selection = values.first
  }

  @ViewBuilder
  private var commandResults: some View {
    ForEach(filteredActions) { action in
      resultRow(selection: .action(action.id)) {
        HStack(spacing: 10) {
          Label(action.title, systemImage: action.systemImage)
          Spacer(minLength: 8)
          Text(action.category)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } perform: {
        action.perform()
        dismiss()
      }
    }
  }

  @ViewBuilder
  private var fileResults: some View {
    ForEach(rankedFiles, id: \.self) { url in
      resultRow(selection: .file(url)) {
        HStack(spacing: 9) {
          CIcon(code: url.pathExtension.lowercased(), size: 13)
          VStack(alignment: .leading, spacing: 1) {
            Text(url.lastPathComponent)
            Text(relativePath(url))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
      } perform: {
        openFile(url)
        dismiss()
      }
    }
  }

  private func resultRow<Content: View>(
    selection rowSelection: Selection,
    @ViewBuilder content: () -> Content,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      content()
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          selection == rowSelection ? Color.accentColor.opacity(0.18) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .id(rowSelection)
  }

  private func relativePath(_ url: URL) -> String {
    let root = workspaceURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return path }
    return String(path.dropFirst(root.count + 1))
  }

  private func reloadProjectFiles() async {
    guard mode != .commands else {
      files = []
      rankedFiles = []
      isScanningProject = false
      updateSelection()
      return
    }
    projectScanGeneration &+= 1
    let generation = projectScanGeneration
    isScanningProject = true
    let nextFiles = await Self.scanFiles(
      root: workspaceURL,
      includeIgnoredFiles: includeIgnoredFiles,
      includeBuildArtifacts: includeBuildArtifacts,
      includeHiddenFiles: includeHiddenFiles,
      includeDSStore: includeDSStore
    )
    guard !Task.isCancelled, generation == projectScanGeneration else { return }
    files = nextFiles
    packageRoots = Self.packageRoots(in: workspaceURL)
    isScanningProject = false
    scheduleFileSearch()
  }

  private func scheduleFileSearch() {
    fileSearchTask?.cancel()
    guard mode != .commands, !isCommandQuery else {
      rankedFiles = []
      isRanking = false
      updateSelection()
      return
    }
    let candidates = files + packageFiles
    let rootURL = workspaceURL
    let value = query
    isRanking = true
    fileSearchTask = Task {
      if !value.isEmpty { try? await Task.sleep(for: .milliseconds(65)) }
      guard !Task.isCancelled else { return }
      let nextFiles = await Self.rankFiles(candidates, rootURL: rootURL, query: value)
      guard !Task.isCancelled, query == value else { return }
      rankedFiles = nextFiles
      isRanking = false
      updateSelection()
    }
  }

  private var packageSearchMenu: some View {
    Menu {
      Button("Project Files Only") {
        selectedPackage = nil
        packageFiles = []
        packageScanTask?.cancel()
        isScanningPackage = false
        scheduleFileSearch()
      }
      if !packageRoots.isEmpty {
        Divider()
        ForEach(packageRoots, id: \.self) { package in
          Button {
            searchInsidePackage(package)
          } label: {
            Label(
              packageDisplayName(package),
              systemImage: selectedPackage == package ? "checkmark" : "folder"
            )
          }
        }
      } else {
        Divider()
        Text("No package directories found")
      }
    } label: {
      Image(systemName: selectedPackage == nil ? "shippingbox" : "shippingbox.fill")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Search Inside Package")
    .help(
      selectedPackage.map { "Searching inside \($0.lastPathComponent)" } ?? "Search Inside Package")
  }

  private func packageDisplayName(_ package: URL) -> String {
    let parent = package.deletingLastPathComponent().lastPathComponent
    return parent.isEmpty ? package.lastPathComponent : "\(parent)/\(package.lastPathComponent)"
  }

  private func searchInsidePackage(_ package: URL) {
    selectedPackage = package
    packageFiles = []
    packageScanTask?.cancel()
    isScanningPackage = true
    packageScanTask = Task {
      let nextFiles = await Self.scanPackageFiles(
        root: package,
        includeHiddenFiles: includeHiddenFiles,
        includeDSStore: includeDSStore
      )
      guard !Task.isCancelled, selectedPackage == package else { return }
      packageFiles = nextFiles
      isScanningPackage = false
      scheduleFileSearch()
    }
  }

  nonisolated private static func rankFiles(_ files: [URL], rootURL: URL, query: String) async
    -> [URL]
  {
    let worker = Task.detached(priority: .userInitiated) { () -> [URL] in
      let rootPath = rootURL.standardizedFileURL.path
      let candidates = files.compactMap { url -> (url: URL, score: Int, path: String)? in
        guard !Task.isCancelled else { return nil }
        let path = Self.relativePath(url, rootPath: rootPath)
        guard query.isEmpty || Self.fuzzyMatch(path, query: query) else { return nil }
        var score = Self.sourceExtensions.contains(url.pathExtension.lowercased()) ? 10_000 : 0
        score += Self.matchScore(url.deletingPathExtension().lastPathComponent, query: query) * 12
        score += Self.matchScore(url.lastPathComponent, query: query) * 8
        score += Self.matchScore(path, query: query)
        score -= min(path.count, 400)
        return (url, score, path)
      }
      return candidates.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }.prefix(140).map(\.url)
    }
    return await worker.value
  }

  nonisolated private static func relativePath(_ url: URL, rootPath: String) -> String {
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return path }
    return String(path.dropFirst(rootPath.count + 1))
  }

  nonisolated private static func fuzzyMatch(_ candidate: String, query: String) -> Bool {
    let candidate = candidate.lowercased()
    let query = query.lowercased()
    if candidate.contains(query) { return true }
    var index = query.startIndex
    for character in candidate where index < query.endIndex {
      if character == query[index] { query.formIndex(after: &index) }
    }
    return index == query.endIndex
  }

  nonisolated private static func matchScore(_ candidate: String, query: String) -> Int {
    guard !query.isEmpty else { return 0 }
    let candidate = candidate.lowercased()
    let query = query.lowercased()
    if candidate == query { return 1_000 }
    if candidate.hasPrefix(query) { return 700 }
    if candidate.contains(query) { return 400 }
    var gapPenalty = 0
    var previousIndex: String.Index?
    var current = query.startIndex
    for index in candidate.indices where current < query.endIndex {
      guard candidate[index] == query[current] else { continue }
      if let previousIndex { gapPenalty += candidate.distance(from: previousIndex, to: index) - 1 }
      previousIndex = index
      query.formIndex(after: &current)
    }
    return current == query.endIndex ? max(1, 200 - gapPenalty) : 0
  }

  nonisolated private static let sourceExtensions: Set<String> = [
    "swift", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm", "rs", "go", "java",
    "kt", "kts", "js", "jsx", "ts", "tsx", "py", "rb", "php", "cs", "fs", "fsx", "scala",
    "zig", "lua", "sh", "zsh", "bash", "html", "css", "scss", "json", "yaml", "yml", "toml", "xml",
  ]

  private struct SearchOptions: Hashable {
    let includeIgnoredFiles: Bool
    let includeBuildArtifacts: Bool
    let includeHiddenFiles: Bool
    let includeDSStore: Bool
  }

  nonisolated private static func scanFiles(
    root: URL,
    includeIgnoredFiles: Bool,
    includeBuildArtifacts: Bool,
    includeHiddenFiles: Bool,
    includeDSStore: Bool
  ) async -> [URL] {
    let worker = Task.detached(priority: .utility) {
      (try? ProjectFileScanner.scan(
        rootURL: root,
        includeIgnoredFiles: includeIgnoredFiles,
        includeBuildArtifacts: includeBuildArtifacts,
        includeHiddenFiles: includeHiddenFiles,
        includeDSStore: includeDSStore
      ).files) ?? []
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  nonisolated private static func packageRoots(in workspaceURL: URL) -> [URL] {
    let relativeCandidates = [
      ".build/checkouts", "SourcePackages/checkouts", "Carthage/Checkouts", "Pods",
      "Packages", "Vendor", "vendor", "ThirdParty", "third_party", "External", "external",
      "Dependencies", "dependencies", "node_modules", ".venv", "venv",
    ]
    var roots: [URL] = []
    for relative in relativeCandidates {
      let candidate = workspaceURL.appendingPathComponent(relative, isDirectory: true)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        roots.append(candidate.standardizedFileURL)
      }
    }
    return Array(Set(roots)).sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
  }

  nonisolated private static func scanPackageFiles(
    root: URL,
    includeHiddenFiles: Bool,
    includeDSStore: Bool
  ) async -> [URL] {
    let worker = Task.detached(priority: .utility) { () -> [URL] in
      let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
      let options: FileManager.DirectoryEnumerationOptions =
        includeHiddenFiles
        ? [.skipsPackageDescendants]
        : [.skipsPackageDescendants, .skipsHiddenFiles]
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: Array(keys),
          options: options
        )
      else { return [] }

      var files: [URL] = []
      while let url = enumerator.nextObject() as? URL {
        guard !Task.isCancelled else { return [] }
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
        if url.lastPathComponent == ".DS_Store", !includeDSStore { continue }
        if sourceExtensions.contains(url.pathExtension.lowercased()) {
          files.append(url.standardizedFileURL)
        }
        if files.count == ProjectFileScanner.maximumNodeCount { break }
      }
      return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}
