import Combine
import Foundation

/// Content that can be hosted by a tab in ``MainSectionalView``.
nonisolated enum MainSectionKind: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
  case workspace
  case editor
  case panel
  case sidebar
  case settings
  case themeBuilder
  case terminal
  case problems
  case buildOutput
  case debug
  case empty

  var id: String { rawValue }

  /// Content exposed by the section tab add/replace menus.
  /// `panel` remains decodable for layouts made by older Calcite builds, but is no longer
  /// presented as a bottom-bar container.
  static var tabCases: [MainSectionKind] {
    allCases.filter { $0 != .panel && $0 != .empty }
  }

  static let bottomPanelKinds: [MainSectionKind] = [
    .terminal,
    .problems,
    .buildOutput,
  ]

  var isBottomPanelKind: Bool {
    Self.bottomPanelKinds.contains(self)
  }

  var title: String {
    switch self {
    case .workspace: "Workspace"
    case .editor: "Editor"
    case .panel: "Panel"
    case .sidebar: "Sidebar"
    case .settings: "Settings"
    case .themeBuilder: "Theme Builder"
    case .terminal: "Terminal"
    case .problems: "Problems"
    case .buildOutput: "Build Output"
    case .debug: "Debug"
    case .empty: "Empty"
    }
  }

  var systemImage: String {
    switch self {
    case .workspace: "rectangle.3.group"
    case .editor: "doc.text"
    case .panel: "rectangle.bottomhalf.inset.filled"
    case .sidebar: "sidebar.left"
    case .settings: "gearshape"
    case .themeBuilder: "paintpalette"
    case .terminal: "terminal"
    case .problems: "exclamationmark.triangle"
    case .buildOutput: "hammer"
    case .debug: "ladybug"
    case .empty: "rectangle.dashed"
    }
  }

  var minimumWidth: Double {
    switch self {
    case .sidebar: 160
    case .settings, .themeBuilder: 300
    case .terminal, .problems, .buildOutput, .debug, .panel: 220
    case .workspace, .editor: 280
    case .empty: 120
    }
  }

  var minimumHeight: Double {
    switch self {
    case .sidebar: 180
    case .settings, .themeBuilder: 240
    case .terminal, .problems, .buildOutput, .debug, .panel: 96
    case .workspace, .editor: 180
    case .empty: 80
    }
  }
}

/// One independently persisted content tab inside a section.
nonisolated struct MainSectionTab: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var kind: MainSectionKind
  var isVisible: Bool

  init(
    id: UUID = UUID(),
    kind: MainSectionKind,
    isVisible: Bool = true
  ) {
    self.id = id
    self.kind = kind
    self.isVisible = isVisible
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case isVisible
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    kind = try container.decode(MainSectionKind.self, forKey: .kind)
    isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
  }
}

nonisolated enum MainSectionSplitAxis: String, Codable, Equatable, Sendable {
  case horizontal
  case vertical
}

nonisolated enum MainSectionDirection: Sendable {
  case left, right, up, down
}

nonisolated enum MainSectionPlacement: Equatable, Sendable {
  case before
  case after
}

nonisolated enum MainSectionalLayoutPreset: String, CaseIterable, Equatable, Identifiable, Sendable
{
  case standard
  case editorFocus
  case sideBySide
  case debugging

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "Standard"
    case .editorFocus: "Editor Focus"
    case .sideBySide: "Side by Side"
    case .debugging: "Debugging"
    }
  }

  var systemImage: String {
    switch self {
    case .standard: "rectangle.3.group"
    case .editorFocus: "rectangle"
    case .sideBySide: "rectangle.split.2x1"
    case .debugging: "ladybug"
    }
  }
}

/// A persistable recursive layout tree. Split nodes own geometry; section nodes own tabs.
nonisolated struct MainSectionLayoutNode: Codable, Equatable, Identifiable, Sendable {
  nonisolated enum NodeType: String, Codable, Equatable, Sendable {
    case section
    case split
  }

  private struct SectionPayload: Equatable {
    var tabs: [MainSectionTab]
    var selectedTabID: UUID?
  }

  var id: UUID
  var type: NodeType
  var tabs: [MainSectionTab]
  var selectedTabID: UUID?
  var showsTabBar: Bool
  var isFastPanel: Bool
  var isSectionVisible: Bool
  var splitAxis: MainSectionSplitAxis?
  var children: [MainSectionLayoutNode]

  private enum CodingKeys: String, CodingKey {
    case id
    case type
    case sectionKind
    case tabs
    case selectedTabID
    case showsTabBar
    case isFastPanel
    case isSectionVisible
    case splitAxis
    case children
  }

  init(
    id: UUID,
    type: NodeType,
    tabs: [MainSectionTab],
    selectedTabID: UUID?,
    showsTabBar: Bool,
    isFastPanel: Bool,
    isSectionVisible: Bool,
    splitAxis: MainSectionSplitAxis?,
    children: [MainSectionLayoutNode]
  ) {
    self.id = id
    self.type = type
    self.tabs = tabs
    self.selectedTabID = selectedTabID
    self.showsTabBar = showsTabBar
    self.isFastPanel = isFastPanel
    self.isSectionVisible = isSectionVisible
    self.splitAxis = splitAxis
    self.children = children
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    type = try container.decode(NodeType.self, forKey: .type)
    splitAxis = try container.decodeIfPresent(MainSectionSplitAxis.self, forKey: .splitAxis)
    children = try container.decodeIfPresent([MainSectionLayoutNode].self, forKey: .children) ?? []

    if type == .section {
      let decodedTabs = try container.decodeIfPresent([MainSectionTab].self, forKey: .tabs) ?? []
      if decodedTabs.isEmpty {
        let legacyKind =
          try container.decodeIfPresent(MainSectionKind.self, forKey: .sectionKind) ?? .empty
        tabs = [MainSectionTab(kind: legacyKind)]
      } else {
        tabs = decodedTabs
      }
      showsTabBar = try container.decodeIfPresent(Bool.self, forKey: .showsTabBar) ?? true
      isFastPanel = try container.decodeIfPresent(Bool.self, forKey: .isFastPanel) ?? false
      isSectionVisible =
        try container.decodeIfPresent(Bool.self, forKey: .isSectionVisible) ?? true
      let decodedSelection = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
      selectedTabID =
        decodedSelection.flatMap { selection in
          tabs.contains(where: { $0.id == selection }) ? selection : nil
        } ?? tabs.first?.id
      splitAxis = nil
      children = []
    } else {
      tabs = []
      selectedTabID = nil
      showsTabBar = false
      isFastPanel = false
      isSectionVisible = true
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(splitAxis, forKey: .splitAxis)
    try container.encode(children, forKey: .children)
    if type == .section {
      try container.encode(tabs, forKey: .tabs)
      try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
      try container.encode(showsTabBar, forKey: .showsTabBar)
      try container.encode(isFastPanel, forKey: .isFastPanel)
      try container.encode(isSectionVisible, forKey: .isSectionVisible)
      try container.encodeIfPresent(sectionKind, forKey: .sectionKind)
    }
  }

  static func section(
    _ kind: MainSectionKind,
    id: UUID = UUID()
  ) -> MainSectionLayoutNode {
    section(tabs: [MainSectionTab(kind: kind)], id: id)
  }

  static func section(
    tabs: [MainSectionTab],
    selectedTabID: UUID? = nil,
    showsTabBar: Bool = true,
    isFastPanel: Bool = false,
    isSectionVisible: Bool = true,
    id: UUID = UUID()
  ) -> MainSectionLayoutNode {
    let safeTabs = tabs.isEmpty ? [MainSectionTab(kind: .empty)] : tabs
    let selection =
      selectedTabID.flatMap { selected in
        safeTabs.contains(where: { $0.id == selected }) ? selected : nil
      } ?? safeTabs.first?.id
    return MainSectionLayoutNode(
      id: id,
      type: .section,
      tabs: safeTabs,
      selectedTabID: selection,
      showsTabBar: showsTabBar,
      isFastPanel: isFastPanel,
      isSectionVisible: isSectionVisible,
      splitAxis: nil,
      children: []
    )
  }

  static func split(
    _ axis: MainSectionSplitAxis,
    children: [MainSectionLayoutNode],
    id: UUID = UUID()
  ) -> MainSectionLayoutNode {
    MainSectionLayoutNode(
      id: id,
      type: .split,
      tabs: [],
      selectedTabID: nil,
      showsTabBar: false,
      isFastPanel: false,
      isSectionVisible: true,
      splitAxis: axis,
      children: children
    ).normalized()
  }

  var selectedTab: MainSectionTab? {
    guard type == .section else { return nil }
    if let selectedTabID, let tab = tabs.first(where: { $0.id == selectedTabID }) {
      return tab
    }
    return tabs.first
  }

  var selectedVisibleTab: MainSectionTab? {
    guard type == .section else { return nil }
    if let selectedTabID,
      let tab = tabs.first(where: { $0.id == selectedTabID && $0.isVisible })
    {
      return tab
    }
    return tabs.first(where: \.isVisible)
  }

  var sectionKind: MainSectionKind? { selectedTab?.kind }
  var visibleTabs: [MainSectionTab] { tabs.filter(\.isVisible) }

  var hasVisibleContent: Bool {
    switch type {
    case .section:
      return isSectionVisible && !visibleTabs.isEmpty
    case .split:
      return children.contains(where: \.hasVisibleContent)
    }
  }

  /// Stable recursive identity used only to distinguish split geometry for temporary visibility
  /// states. It intentionally ignores selected tabs and other presentation state.
  func geometryVisibilitySignature(visibleOnly: Bool) -> String {
    switch type {
    case .section:
      guard !visibleOnly || hasVisibleContent else { return "" }
      return "section:\(id.uuidString)"
    case .split:
      let includedChildren = visibleOnly ? children.filter(\.hasVisibleContent) : children
      let childSignature =
        includedChildren
        .map { $0.geometryVisibilitySignature(visibleOnly: visibleOnly) }
        .filter { !$0.isEmpty }
        .joined(separator: ",")
      return "split:\(id.uuidString)[\(childSignature)]"
    }
  }

  var leafCount: Int {
    switch type {
    case .section:
      return 1
    case .split:
      return children.reduce(0) { $0 + $1.leafCount }
    }
  }

  var sectionKinds: [MainSectionKind] {
    switch type {
    case .section:
      return tabs.map(\.kind)
    case .split:
      return children.flatMap(\.sectionKinds)
    }
  }

  var sectionNodes: [MainSectionLayoutNode] {
    switch type {
    case .section:
      return [self]
    case .split:
      return children.flatMap(\.sectionNodes)
    }
  }

  var visibleSectionIDs: [UUID] {
    switch type {
    case .section:
      return hasVisibleContent ? [id] : []
    case .split:
      return children.flatMap(\.visibleSectionIDs)
    }
  }

  var fastPanelSectionIDs: [UUID] {
    switch type {
    case .section:
      return isFastPanel ? [id] : []
    case .split:
      return children.flatMap(\.fastPanelSectionIDs)
    }
  }

  func containsSection(_ id: UUID) -> Bool {
    if type == .section { return self.id == id }
    return children.contains { $0.containsSection(id) }
  }

  func contains(kind: MainSectionKind, visibleOnly: Bool = false) -> Bool {
    switch type {
    case .section:
      return tabs.contains {
        $0.kind == kind && (!visibleOnly || (isSectionVisible && $0.isVisible))
      }
    case .split:
      return children.contains { $0.contains(kind: kind, visibleOnly: visibleOnly) }
    }
  }

  func sectionNode(id sectionID: UUID) -> MainSectionLayoutNode? {
    switch type {
    case .section:
      return id == sectionID ? self : nil
    case .split:
      for child in children {
        if let section = child.sectionNode(id: sectionID) { return section }
      }
      return nil
    }
  }

  func sectionKind(for id: UUID) -> MainSectionKind? {
    if type == .section {
      return self.id == id ? sectionKind : nil
    }
    for child in children {
      if let kind = child.sectionKind(for: id) { return kind }
    }
    return nil
  }

  func sectionIDs(kind: MainSectionKind, visibleOnly: Bool = false) -> [UUID] {
    switch type {
    case .section:
      return contains(kind: kind, visibleOnly: visibleOnly) ? [id] : []
    case .split:
      return children.flatMap { $0.sectionIDs(kind: kind, visibleOnly: visibleOnly) }
    }
  }

  func tabIDs(kind: MainSectionKind, visibleOnly: Bool = false) -> [UUID] {
    switch type {
    case .section:
      return tabs.compactMap { tab in
        tab.kind == kind && (!visibleOnly || (isSectionVisible && tab.isVisible)) ? tab.id : nil
      }
    case .split:
      return children.flatMap { $0.tabIDs(kind: kind, visibleOnly: visibleOnly) }
    }
  }

  func sectionID(containingTab tabID: UUID) -> UUID? {
    switch type {
    case .section:
      return tabs.contains(where: { $0.id == tabID }) ? id : nil
    case .split:
      for child in children {
        if let sectionID = child.sectionID(containingTab: tabID) { return sectionID }
      }
      return nil
    }
  }

  func firstSectionID(preferredKinds: [MainSectionKind] = []) -> UUID? {
    switch type {
    case .section:
      if preferredKinds.isEmpty || preferredKinds.contains(where: { contains(kind: $0) }) {
        return id
      }
      return nil
    case .split:
      for child in children {
        if let id = child.firstSectionID(preferredKinds: preferredKinds) { return id }
      }
      return preferredKinds.isEmpty ? nil : firstSectionID()
    }
  }

  mutating func selectTab(sectionID: UUID, tabID: UUID) -> Bool {
    updateSection(id: sectionID) { section in
      guard section.tabs.contains(where: { $0.id == tabID && $0.isVisible }),
        section.selectedTabID != tabID
      else { return false }
      section.selectedTabID = tabID
      return true
    }
  }

  @discardableResult
  mutating func addTab(
    sectionID: UUID,
    kind: MainSectionKind,
    select: Bool = true,
    tabID: UUID = UUID()
  ) -> UUID? {
    let tab = MainSectionTab(id: tabID, kind: kind)
    guard
      updateSection(
        id: sectionID,
        { section in
          if section.tabs.count == 1, section.tabs[0].kind == .empty {
            section.tabs = [tab]
          } else {
            section.tabs.append(tab)
          }
          if select { section.selectedTabID = tab.id }
          return true
        })
    else { return nil }
    return tab.id
  }

  mutating func removeTab(sectionID: UUID, tabID: UUID) -> Bool {
    updateSection(id: sectionID) { section in
      guard let index = section.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
      section.tabs.remove(at: index)
      if section.tabs.isEmpty {
        let empty = MainSectionTab(kind: .empty)
        section.tabs = [empty]
        section.selectedTabID = empty.id
      } else if section.selectedTabID == tabID {
        let fallbackIndex = min(index, section.tabs.count - 1)
        section.selectedTabID =
          section.tabs.dropFirst(fallbackIndex).first(where: \.isVisible)?.id
          ?? section.tabs.first(where: \.isVisible)?.id
          ?? section.tabs[fallbackIndex].id
      }
      return true
    }
  }

  mutating func replaceTab(
    sectionID: UUID,
    tabID: UUID,
    with kind: MainSectionKind
  ) -> Bool {
    updateSection(id: sectionID) { section in
      guard let index = section.tabs.firstIndex(where: { $0.id == tabID }),
        section.tabs[index].kind != kind
      else { return false }
      section.tabs[index].kind = kind
      section.tabs[index].isVisible = true
      section.selectedTabID = tabID
      return true
    }
  }

  mutating func replaceSection(id: UUID, with kind: MainSectionKind) -> Bool {
    guard let selectedTabID = selectedTabID(in: id) else { return false }
    return replaceTab(sectionID: id, tabID: selectedTabID, with: kind)
  }

  mutating func splitSection(
    id: UUID,
    axis: MainSectionSplitAxis,
    newKind: MainSectionKind,
    placement: MainSectionPlacement = .after
  ) -> Bool {
    splitSection(
      id: id,
      axis: axis,
      newSection: .section(newKind),
      placement: placement
    )
  }

  mutating func splitSection(
    id: UUID,
    axis: MainSectionSplitAxis,
    newSection: MainSectionLayoutNode,
    placement: MainSectionPlacement = .after
  ) -> Bool {
    switch type {
    case .section:
      guard self.id == id else { return false }
      let original = self
      let ordered = placement == .before ? [newSection, original] : [original, newSection]
      self = .split(axis, children: ordered)
      return true

    case .split:
      guard let splitAxis else { return false }
      if splitAxis == axis,
        let directIndex = children.firstIndex(where: { $0.type == .section && $0.id == id })
      {
        let insertionIndex = placement == .before ? directIndex : directIndex + 1
        children.insert(newSection, at: insertionIndex)
        return true
      }
      for index in children.indices {
        if children[index].splitSection(
          id: id,
          axis: axis,
          newSection: newSection,
          placement: placement
        ) {
          return true
        }
      }
      return false
    }
  }

  mutating func swapSectionKinds(_ firstID: UUID, _ secondID: UUID) -> Bool {
    guard firstID != secondID,
      let firstPayload = sectionPayload(for: firstID),
      let secondPayload = sectionPayload(for: secondID),
      firstPayload != secondPayload
    else { return false }

    let replacedFirst = replaceSectionPayload(id: firstID, with: secondPayload)
    let replacedSecond = replaceSectionPayload(id: secondID, with: firstPayload)
    return replacedFirst && replacedSecond
  }

  mutating func setTabBarVisible(sectionID: UUID, isVisible: Bool) -> Bool {
    updateSection(id: sectionID) { section in
      guard section.showsTabBar != isVisible else { return false }
      section.showsTabBar = isVisible
      return true
    }
  }

  mutating func setFastPanel(sectionID: UUID, isFastPanel: Bool) -> Bool {
    updateSection(id: sectionID) { section in
      guard section.isFastPanel != isFastPanel else { return false }
      section.isFastPanel = isFastPanel
      return true
    }
  }

  mutating func setSectionVisible(sectionID: UUID, isVisible: Bool) -> Bool {
    updateSection(id: sectionID) { section in
      guard section.isSectionVisible != isVisible else { return false }
      section.isSectionVisible = isVisible
      return true
    }
  }

  mutating func setTabVisible(tabID: UUID, isVisible: Bool) -> Bool {
    switch type {
    case .section:
      guard let index = tabs.firstIndex(where: { $0.id == tabID }),
        tabs[index].isVisible != isVisible
      else { return false }
      tabs[index].isVisible = isVisible
      return true
    case .split:
      for index in children.indices {
        if children[index].setTabVisible(tabID: tabID, isVisible: isVisible) { return true }
      }
      return false
    }
  }

  mutating func setTabsVisible(kind: MainSectionKind, isVisible: Bool) -> Bool {
    switch type {
    case .section:
      var changed = false
      for index in tabs.indices where tabs[index].kind == kind && tabs[index].isVisible != isVisible
      {
        tabs[index].isVisible = isVisible
        changed = true
      }
      return changed
    case .split:
      var changed = false
      for index in children.indices {
        changed = children[index].setTabsVisible(kind: kind, isVisible: isVisible) || changed
      }
      return changed
    }
  }

  mutating func setTabsVisible(
    sectionID: UUID,
    kinds: [MainSectionKind],
    isVisible: Bool
  ) -> Bool {
    updateSection(id: sectionID) { section in
      var changed = false
      for index in section.tabs.indices
      where kinds.contains(section.tabs[index].kind)
        && section.tabs[index].isVisible != isVisible
      {
        section.tabs[index].isVisible = isVisible
        changed = true
      }
      return changed
    }
  }

  mutating func removeSection(id: UUID) -> Bool {
    guard leafCount > 1 else { return false }
    let result = removingSection(id: id)
    guard result.removed, let node = result.node else { return false }
    self = node.normalized()
    return true
  }

  func normalized() -> MainSectionLayoutNode {
    switch type {
    case .section:
      let safeTabs = tabs.isEmpty ? [MainSectionTab(kind: .empty)] : tabs
      let safeSelection =
        selectedTabID.flatMap { selection in
          safeTabs.contains(where: { $0.id == selection }) ? selection : nil
        } ?? safeTabs.first?.id
      return .section(
        tabs: safeTabs,
        selectedTabID: safeSelection,
        showsTabBar: showsTabBar,
        isFastPanel: isFastPanel,
        isSectionVisible: isSectionVisible,
        id: id
      )

    case .split:
      let normalizedChildren = children.map { $0.normalized() }
      guard let splitAxis else { return normalizedChildren.first ?? .section(.workspace) }
      if normalizedChildren.isEmpty { return .section(.workspace) }
      if normalizedChildren.count == 1 { return normalizedChildren[0] }
      return MainSectionLayoutNode(
        id: id,
        type: .split,
        tabs: [],
        selectedTabID: nil,
        showsTabBar: false,
        isFastPanel: false,
        isSectionVisible: true,
        splitAxis: splitAxis,
        children: normalizedChildren
      )
    }
  }

  private func selectedTabID(in sectionID: UUID) -> UUID? {
    switch type {
    case .section:
      return id == sectionID ? selectedTab?.id : nil
    case .split:
      for child in children {
        if let id = child.selectedTabID(in: sectionID) { return id }
      }
      return nil
    }
  }

  private mutating func updateSection(
    id sectionID: UUID,
    _ operation: (inout MainSectionLayoutNode) -> Bool
  ) -> Bool {
    switch type {
    case .section:
      guard id == sectionID else { return false }
      return operation(&self)
    case .split:
      for index in children.indices {
        if children[index].updateSection(id: sectionID, operation) { return true }
      }
      return false
    }
  }

  private func sectionPayload(for sectionID: UUID) -> SectionPayload? {
    switch type {
    case .section:
      return id == sectionID ? SectionPayload(tabs: tabs, selectedTabID: selectedTabID) : nil
    case .split:
      for child in children {
        if let payload = child.sectionPayload(for: sectionID) { return payload }
      }
      return nil
    }
  }

  private mutating func replaceSectionPayload(
    id sectionID: UUID,
    with payload: SectionPayload
  ) -> Bool {
    updateSection(id: sectionID) { section in
      section.tabs = payload.tabs
      section.selectedTabID = payload.selectedTabID
      return true
    }
  }

  private func removingSection(
    id targetID: UUID
  ) -> (node: MainSectionLayoutNode?, removed: Bool) {
    switch type {
    case .section:
      return id == targetID ? (nil, true) : (self, false)
    case .split:
      var didRemove = false
      var updatedChildren: [MainSectionLayoutNode] = []
      updatedChildren.reserveCapacity(children.count)
      for child in children {
        if didRemove {
          updatedChildren.append(child)
          continue
        }
        let result = child.removingSection(id: targetID)
        didRemove = result.removed
        if let node = result.node { updatedChildren.append(node) }
      }
      guard didRemove else { return (self, false) }
      if updatedChildren.isEmpty { return (nil, true) }
      if updatedChildren.count == 1 { return (updatedChildren[0], true) }
      return (
        MainSectionLayoutNode(
          id: id,
          type: .split,
          tabs: [],
          selectedTabID: nil,
          showsTabBar: false,
          isFastPanel: false,
          isSectionVisible: true,
          splitAxis: splitAxis ?? .horizontal,
          children: updatedChildren
        ).normalized(),
        true
      )
    }
  }
}

@MainActor
final class MainSectionalLayoutController: ObservableObject {
  @Published private(set) var root: MainSectionLayoutNode
  @Published var isCustomizing = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var swapSourceSectionID: UUID?
  @Published private(set) var activeSectionID: UUID?

  private let workspaceURL: URL
  private let defaults: UserDefaults
  private let includesSidebarByDefault: Bool
  private var undoStack: [MainSectionLayoutNode] = []
  private var redoStack: [MainSectionLayoutNode] = []

  init(
    workspaceURL: URL,
    defaults: UserDefaults = .standard,
    includesPanelByDefault _: Bool = false,
    includesSidebarByDefault: Bool = true
  ) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.defaults = defaults
    self.includesSidebarByDefault = includesSidebarByDefault
    self.root =
      Self.load(workspaceURL: workspaceURL, defaults: defaults)
      ?? Self.makePreset(.standard, includesSidebar: includesSidebarByDefault)
    self.activeSectionID =
      root.sectionNodes.first {
        $0.hasVisibleContent && ($0.contains(kind: .workspace) || $0.contains(kind: .editor))
      }?.id
      ?? root.visibleSectionIDs.first
      ?? root.firstSectionID()
  }

  var leafCount: Int { root.leafCount }

  var activeSelectedKind: MainSectionKind? {
    guard let activeSectionID else { return nil }
    return root.sectionKind(for: activeSectionID)
  }

  var fastPanelSectionIDs: [UUID] { root.fastPanelSectionIDs }

  var visibleFastPanelSectionCount: Int {
    fastPanelSectionIDs.reduce(into: 0) { count, sectionID in
      if root.sectionNode(id: sectionID)?.hasVisibleContent == true { count += 1 }
    }
  }

  var areAllFastPanelsVisible: Bool {
    !fastPanelSectionIDs.isEmpty && visibleFastPanelSectionCount == fastPanelSectionIDs.count
  }

  func isFastPanel(_ sectionID: UUID) -> Bool {
    root.sectionNode(id: sectionID)?.isFastPanel == true
  }

  func isSectionVisible(_ sectionID: UUID) -> Bool {
    root.sectionNode(id: sectionID)?.hasVisibleContent == true
  }

  func splitAutosaveName(for splitID: UUID) -> String {
    let workspaceID = Self.stableIdentifier(workspaceURL.standardizedFileURL.path)
    return "Calcite.mainSectionalSplit.\(workspaceID).\(splitID.uuidString)"
  }

  func splitAutosaveName(
    for splitID: UUID,
    visibleGeometrySignature: String,
    fullGeometrySignature: String
  ) -> String {
    let base = splitAutosaveName(for: splitID)
    guard visibleGeometrySignature != fullGeometrySignature else { return base }
    return "\(base).visible.\(Self.stableIdentifier(visibleGeometrySignature))"
  }

  func contains(_ kind: MainSectionKind) -> Bool {
    root.contains(kind: kind)
  }

  func containsVisible(_ kind: MainSectionKind) -> Bool {
    root.contains(kind: kind, visibleOnly: true)
  }

  var isBottomPanelVisible: Bool {
    guard let sectionID = bottomPanelSectionID(),
      let section = root.sectionNode(id: sectionID),
      section.isSectionVisible
    else { return false }
    return section.tabs.contains { tab in
      tab.isVisible && tab.kind.isBottomPanelKind
    }
  }

  func activateSection(_ id: UUID) {
    guard root.containsSection(id) else { return }
    activeSectionID = id
  }

  func setFastPanel(_ isFastPanel: Bool, for sectionID: UUID) {
    updateWithoutHistory { $0.setFastPanel(sectionID: sectionID, isFastPanel: isFastPanel) }
  }

  func toggleFastPanelMembership(for sectionID: UUID) {
    setFastPanel(!isFastPanel(sectionID), for: sectionID)
  }

  /// Toggles one section immediately from its own header. The first use also makes the section
  /// available to the workspace-wide Fast Panels shortcut.
  func toggleSectionFastPanel(for sectionID: UUID) {
    guard root.containsSection(sectionID) else { return }
    if !isFastPanel(sectionID) {
      setFastPanel(true, for: sectionID)
    }
    setSectionVisible(!isSectionVisible(sectionID), for: sectionID)
  }

  func setSectionVisible(_ isVisible: Bool, for sectionID: UUID) {
    updateWithoutHistory { $0.setSectionVisible(sectionID: sectionID, isVisible: isVisible) }
    if isVisible {
      activeSectionID = sectionID
    } else if activeSectionID == sectionID {
      activeSectionID = root.visibleSectionIDs.first
    }
  }

  func toggleFastPanels() {
    let sectionIDs = fastPanelSectionIDs
    guard !sectionIDs.isEmpty else { return }
    let shouldShow = !areAllFastPanelsVisible
    updateWithoutHistory { root in
      var changed = false
      for sectionID in sectionIDs {
        changed = root.setSectionVisible(sectionID: sectionID, isVisible: shouldShow) || changed
        if shouldShow,
          let section = root.sectionNode(id: sectionID),
          section.visibleTabs.isEmpty
        {
          for tab in section.tabs {
            changed = root.setTabVisible(tabID: tab.id, isVisible: true) || changed
          }
        }
      }
      return changed
    }
    if shouldShow {
      activeSectionID = sectionIDs.first
    } else if let activeSectionID, sectionIDs.contains(activeSectionID) {
      self.activeSectionID = root.visibleSectionIDs.first
    }
  }

  @discardableResult
  func navigateSection(forward: Bool) -> UUID? {
    let sectionIDs = root.visibleSectionIDs
    guard !sectionIDs.isEmpty else { return nil }
    let currentIndex =
      activeSectionID.flatMap { sectionIDs.firstIndex(of: $0) }
      ?? (forward ? -1 : 0)
    let nextIndex: Int
    if forward {
      nextIndex = (currentIndex + 1) % sectionIDs.count
    } else {
      nextIndex = (currentIndex - 1 + sectionIDs.count) % sectionIDs.count
    }
    let sectionID = sectionIDs[nextIndex]
    activeSectionID = sectionID
    return sectionID
  }

  /// Move to the section nearest the active section in a physical direction.
  /// Split topology is used as a lightweight geometry model, so this also works
  /// before SwiftUI has laid out the workbench.
  @discardableResult
  func navigateSection(direction: MainSectionDirection) -> UUID? {
    guard let activeSectionID,
      let currentIndex = root.visibleSectionIDs.firstIndex(of: activeSectionID)
    else { return nil }
    let ids = root.visibleSectionIDs
    guard ids.count > 1 else { return activeSectionID }

    let targetIndex: Int
    switch direction {
    case .left, .up:
      targetIndex = max(0, currentIndex - 1)
    case .right, .down:
      targetIndex = min(ids.count - 1, currentIndex + 1)
    }
    let sectionID = ids[targetIndex]
    self.activeSectionID = sectionID
    return sectionID
  }

  func selectTab(sectionID: UUID, tabID: UUID) {
    var updated = root
    guard updated.selectTab(sectionID: sectionID, tabID: tabID) else { return }
    root = updated
    activeSectionID = sectionID
    persist()
  }

  func setTabBarVisible(sectionID: UUID, isVisible: Bool) {
    mutate { $0.setTabBarVisible(sectionID: sectionID, isVisible: isVisible) }
  }

  func addTab(to sectionID: UUID, kind: MainSectionKind) {
    if let existingTabID = existingTabID(for: kind, in: sectionID) {
      updateWithoutHistory { root in
        let visibilityChanged = root.setTabVisible(tabID: existingTabID, isVisible: true)
        let selectionChanged = root.selectTab(sectionID: sectionID, tabID: existingTabID)
        return visibilityChanged || selectionChanged
      }
      activeSectionID = sectionID
      return
    }

    mutate { root in root.addTab(sectionID: sectionID, kind: kind) != nil }
    activeSectionID = sectionID
  }

  func removeTab(sectionID: UUID, tabID: UUID) {
    mutate { $0.removeTab(sectionID: sectionID, tabID: tabID) }
  }

  func replaceTab(sectionID: UUID, tabID: UUID, with kind: MainSectionKind) {
    mutate { $0.replaceTab(sectionID: sectionID, tabID: tabID, with: kind) }
    activeSectionID = sectionID
  }

  func replaceSection(id: UUID, with kind: MainSectionKind) {
    mutate { $0.replaceSection(id: id, with: kind) }
    activeSectionID = id
  }

  func splitSection(
    id: UUID,
    axis: MainSectionSplitAxis,
    newKind: MainSectionKind,
    placement: MainSectionPlacement = .after
  ) {
    mutate {
      $0.splitSection(id: id, axis: axis, newKind: newKind, placement: placement)
    }
  }

  func splitSection(
    id: UUID,
    axis: MainSectionSplitAxis,
    newSection: MainSectionLayoutNode,
    placement: MainSectionPlacement = .after
  ) {
    mutate {
      $0.splitSection(id: id, axis: axis, newSection: newSection, placement: placement)
    }
  }

  func removeSection(id: UUID) {
    mutate { $0.removeSection(id: id) }
  }

  func splitActiveSection(axis: MainSectionSplitAxis) {
    guard let activeSectionID else { return }
    splitSection(id: activeSectionID, axis: axis, newKind: .editor)
  }

  func closeActiveSection() {
    guard let activeSectionID, leafCount > 1 else { return }
    removeSection(id: activeSectionID)
    self.activeSectionID =
      root.firstSectionID(preferredKinds: [.workspace, .editor])
      ?? root.firstSectionID()
  }

  func swapSections(_ firstID: UUID, _ secondID: UUID) {
    mutate { $0.swapSectionKinds(firstID, secondID) }
  }

  func selectSectionForSwap(_ id: UUID) {
    guard root.containsSection(id) else { return }
    swapSourceSectionID = id
  }

  func swapWithSelectedSection(_ id: UUID) {
    guard let sourceID = swapSourceSectionID else {
      selectSectionForSwap(id)
      return
    }
    defer { swapSourceSectionID = nil }
    guard sourceID != id else { return }
    swapSections(sourceID, id)
  }

  func cancelSectionSwap() {
    swapSourceSectionID = nil
  }

  /// Sidebar visibility changes only the sidebar tab's presentation state. The section tree,
  /// section UUIDs, sibling tabs, and split autosave identity remain untouched.
  func setSidebarVisible(_ isVisible: Bool) {
    if root.contains(kind: .sidebar) {
      updateWithoutHistory { root in
        var changed = root.setTabsVisible(kind: .sidebar, isVisible: isVisible)
        if isVisible {
          for sectionID in root.sectionIDs(kind: .sidebar) {
            changed = root.setSectionVisible(sectionID: sectionID, isVisible: true) || changed
          }
        }
        return changed
      }
      return
    }
    guard isVisible, let sectionID = preferredTargetSectionID() else { return }
    addTab(to: sectionID, kind: .sidebar)
  }

  /// Shows or hides the canonical bottom section without replacing or removing sibling sections.
  func setBottomPanelVisible(_ isVisible: Bool) {
    guard let sectionID = bottomPanelSectionID() ?? (isVisible ? createBottomPanelSection() : nil)
    else { return }

    updateWithoutHistory { root in
      let tabsChanged = root.setTabsVisible(
        sectionID: sectionID,
        kinds: MainSectionKind.bottomPanelKinds,
        isVisible: isVisible
      )
      let sectionChanged =
        isVisible
        ? root.setSectionVisible(sectionID: sectionID, isVisible: true)
        : false
      return tabsChanged || sectionChanged
    }

    if isVisible {
      activeSectionID = sectionID
    } else if activeSectionID == sectionID {
      activeSectionID =
        root.firstSectionID(preferredKinds: [.workspace, .editor])
        ?? root.firstSectionID()
    }
  }

  func toggleBottomPanel() {
    setBottomPanelVisible(!isBottomPanelVisible)
  }

  /// Presents a utility as a section tab instead of opening a bottom bar.
  func presentTab(_ kind: MainSectionKind) {
    if kind.isBottomPanelKind {
      guard let sectionID = bottomPanelSectionID() ?? createBottomPanelSection() else { return }
      if existingTabID(for: kind, in: sectionID) == nil {
        addTab(to: sectionID, kind: kind)
      }
      updateWithoutHistory { root in
        let visibilityChanged = root.setTabsVisible(
          sectionID: sectionID,
          kinds: MainSectionKind.bottomPanelKinds,
          isVisible: true
        )
        guard let tabID = self.tabID(kind: kind, in: sectionID) else {
          return visibilityChanged
        }
        let sectionChanged = root.setSectionVisible(sectionID: sectionID, isVisible: true)
        let selectionChanged = root.selectTab(sectionID: sectionID, tabID: tabID)
        return visibilityChanged || sectionChanged || selectionChanged
      }
      activeSectionID = sectionID
      return
    }

    let preferredSectionID = preferredTargetSectionID()
    let candidateIDs = root.sectionIDs(kind: kind)
    let sectionID =
      preferredSectionID.flatMap { candidateIDs.contains($0) ? $0 : nil }
      ?? candidateIDs.first

    if let sectionID,
      let tabID = tabID(kind: kind, in: sectionID)
    {
      updateWithoutHistory { root in
        let visibilityChanged = root.setTabVisible(tabID: tabID, isVisible: true)
        let selectionChanged = root.selectTab(sectionID: sectionID, tabID: tabID)
        return visibilityChanged || selectionChanged
      }
      activeSectionID = sectionID
      return
    }

    guard let target = preferredSectionID else { return }
    addTab(to: target, kind: kind)
  }

  func applyPreset(_ preset: MainSectionalLayoutPreset) {
    commit(Self.makePreset(preset, includesSidebar: includesSidebarByDefault))
  }

  func reset() {
    commit(Self.makePreset(.standard, includesSidebar: includesSidebarByDefault))
  }

  func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(root)
    root = previous
    clearInvalidSelections()
    persist()
    refreshHistoryAvailability()
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(root)
    root = next
    clearInvalidSelections()
    persist()
    refreshHistoryAvailability()
  }

  private func bottomPanelSectionID() -> UUID? {
    root.sectionNodes
      .map { section in
        (
          id: section.id,
          score: section.tabs.reduce(into: 0) { count, tab in
            if tab.kind.isBottomPanelKind { count += 1 }
          }
        )
      }
      .filter { $0.score > 0 }
      .max { lhs, rhs in lhs.score < rhs.score }?
      .id
  }

  private func createBottomPanelSection() -> UUID? {
    guard
      let editorSectionID =
        root.firstSectionID(preferredKinds: [.workspace, .editor])
        ?? root.firstSectionID()
    else { return nil }

    let terminal = MainSectionTab(kind: .terminal)
    let problems = MainSectionTab(kind: .problems)
    let buildOutput = MainSectionTab(kind: .buildOutput)
    let sectionID = UUID()
    let section = MainSectionLayoutNode.section(
      tabs: [terminal, problems, buildOutput],
      selectedTabID: terminal.id,
      id: sectionID
    )
    var updated = root
    guard
      updated.splitSection(
        id: editorSectionID,
        axis: .vertical,
        newSection: section,
        placement: .after
      )
    else { return nil }
    commit(updated.normalized())
    return sectionID
  }

  private func preferredTargetSectionID() -> UUID? {
    if let activeSectionID, root.containsSection(activeSectionID) { return activeSectionID }
    return root.firstSectionID(preferredKinds: [.workspace, .editor]) ?? root.firstSectionID()
  }

  private func tabID(kind: MainSectionKind, in sectionID: UUID) -> UUID? {
    root.tabIDs(kind: kind).first { root.sectionID(containingTab: $0) == sectionID }
  }

  private func existingTabID(for kind: MainSectionKind, in sectionID: UUID) -> UUID? {
    let equivalentKinds: [MainSectionKind]
    switch kind {
    case .workspace, .editor:
      equivalentKinds = [.workspace, .editor]
    case .panel:
      equivalentKinds = [.panel, .terminal]
    case .terminal:
      equivalentKinds = [.terminal, .panel]
    case .sidebar, .settings, .themeBuilder, .problems, .buildOutput, .debug, .empty:
      equivalentKinds = [kind]
    }

    for candidate in equivalentKinds {
      if let tabID = tabID(kind: candidate, in: sectionID) { return tabID }
    }
    return nil
  }

  private func mutate(_ operation: (inout MainSectionLayoutNode) -> Bool) {
    var updated = root
    guard operation(&updated) else { return }
    commit(updated.normalized())
  }

  private func updateWithoutHistory(_ operation: (inout MainSectionLayoutNode) -> Bool) {
    var updated = root
    guard operation(&updated) else { return }
    root = updated.normalized()
    clearInvalidSelections()
    persist()
  }

  private func commit(_ updated: MainSectionLayoutNode) {
    let normalized = updated.normalized()
    guard normalized != root else { return }
    undoStack.append(root)
    if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
    redoStack.removeAll(keepingCapacity: true)
    root = normalized
    clearInvalidSelections()
    persist()
    refreshHistoryAvailability()
  }

  private func clearInvalidSelections() {
    if let swapSourceSectionID, !root.containsSection(swapSourceSectionID) {
      self.swapSourceSectionID = nil
    }
    if let activeSectionID,
      !root.containsSection(activeSectionID)
        || root.sectionNode(id: activeSectionID)?.hasVisibleContent != true
    {
      self.activeSectionID =
        root.sectionNodes.first {
          $0.hasVisibleContent && ($0.contains(kind: .workspace) || $0.contains(kind: .editor))
        }?.id
        ?? root.visibleSectionIDs.first
        ?? root.firstSectionID()
    }
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(root) else { return }
    defaults.set(data, forKey: Self.storageKey(for: workspaceURL))
  }

  private func refreshHistoryAvailability() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }

  private static func load(
    workspaceURL: URL,
    defaults: UserDefaults
  ) -> MainSectionLayoutNode? {
    guard let data = defaults.data(forKey: storageKey(for: workspaceURL)),
      let decoded = try? JSONDecoder().decode(MainSectionLayoutNode.self, from: data),
      decoded.leafCount > 0
    else { return nil }
    return decoded.normalized()
  }

  private static func storageKey(for workspaceURL: URL) -> String {
    let path = workspaceURL.standardizedFileURL.path
    let encodedPath = Data(path.utf8).base64EncodedString()
    return "Calcite.mainSectionalLayout.\(encodedPath)"
  }

  private static func stableIdentifier(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  private static func makePreset(
    _ preset: MainSectionalLayoutPreset,
    includesSidebar: Bool
  ) -> MainSectionLayoutNode {
    let editor = MainSectionLayoutNode.section(.editor)
    let terminal = MainSectionTab(kind: .terminal)
    let problems = MainSectionTab(kind: .problems)
    let buildOutput = MainSectionTab(kind: .buildOutput)
    let bottom = MainSectionLayoutNode.section(
      tabs: [terminal, problems, buildOutput],
      selectedTabID: terminal.id,
      isFastPanel: true
    )
    let standardWorkbench = MainSectionLayoutNode.split(
      .vertical,
      children: [editor, bottom]
    )

    switch preset {
    case .standard:
      guard includesSidebar else { return standardWorkbench }
      let sidebar = MainSectionLayoutNode.section(
        tabs: [MainSectionTab(kind: .sidebar)],
        showsTabBar: false,
        isFastPanel: true
      )
      return .split(.horizontal, children: [sidebar, standardWorkbench])

    case .editorFocus:
      return .section(.editor)

    case .sideBySide:
      return .split(.horizontal, children: [.section(.editor), .section(.editor)])

    case .debugging:
      let debug = MainSectionTab(kind: .debug)
      let debuggingBottom = MainSectionLayoutNode.section(
        tabs: [terminal, problems, buildOutput, debug],
        selectedTabID: debug.id,
        isFastPanel: true
      )
      let debuggingWorkbench = MainSectionLayoutNode.split(
        .vertical,
        children: [.section(.editor), debuggingBottom]
      )
      guard includesSidebar else { return debuggingWorkbench }
      let sidebar = MainSectionLayoutNode.section(
        tabs: [MainSectionTab(kind: .sidebar)],
        showsTabBar: false,
        isFastPanel: true
      )
      return .split(.horizontal, children: [sidebar, debuggingWorkbench])
    }

  }
}
