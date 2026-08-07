import Combine
import Foundation

/// Content that can be hosted by a tab in ``MainSectionalView``.
nonisolated enum MainSectionKind: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
  case workspace
  case editor
  case panel
  case sidebar
  case symbols
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

  var isEditorHost: Bool {
    self == .workspace || self == .editor
  }

  var title: String {
    switch self {
    case .workspace: "Workspace"
    case .editor: "Editor"
    case .panel: "Panel"
    case .sidebar: "Sidebar"
    case .symbols: "Symbols"
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
    case .symbols: "list.bullet.indent"
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
    case .sidebar, .symbols: 160
    case .settings, .themeBuilder: 300
    case .terminal, .problems, .buildOutput, .debug, .panel: 220
    case .workspace, .editor: 280
    case .empty: 120
    }
  }

  var minimumHeight: Double {
    switch self {
    case .sidebar, .symbols: 180
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

nonisolated enum MainSectionDirection: Equatable, Sendable {
  case left, right, up, down
}

nonisolated enum MainSectionPlacement: Equatable, Sendable {
  case before
  case after
}

nonisolated enum MainSectionalLayoutPreset: String, CaseIterable, Codable, Equatable, Identifiable,
  Sendable
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
  /// states. It intentionally ignores selected tabs and other presentation state. Hidden fast-panel
  /// placeholders remain part of the identity because they are still rendered as split children.
  func geometryVisibilitySignature(visibleOnly: Bool) -> String {
    switch type {
    case .section:
      let visibility = hasVisibleContent ? "visible" : "hidden"
      let fastPanel = isFastPanel ? "fast" : "normal"
      return "section:\(id.uuidString):\(visibility):\(fastPanel)"
    case .split:
      let childSignature =
        children
        .map { child -> String in
          if visibleOnly, !child.hasVisibleContent, child.fastPanelSectionIDs.isEmpty {
            return "omitted:\(child.id.uuidString)"
          }
          return child.geometryVisibilitySignature(visibleOnly: visibleOnly)
        }
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

  var splitNodes: [MainSectionLayoutNode] {
    switch type {
    case .section:
      return []
    case .split:
      return [self] + children.flatMap(\.splitNodes)
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

  /// Visible section leaves that can host a Vim editor window.
  ///
  /// A section remains a Vim window even when one of its utility tabs is selected. Vim window
  /// navigation selects the section's editor-host tab before transferring focus.
  var visibleVimEditorSectionIDs: [UUID] {
    switch type {
    case .section:
      guard isSectionVisible,
        tabs.contains(where: { $0.isVisible && $0.kind.isEditorHost })
      else { return [] }
      return [id]
    case .split:
      return children.flatMap(\.visibleVimEditorSectionIDs)
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

  func vimEditorTabID(in sectionID: UUID) -> UUID? {
    guard let section = sectionNode(id: sectionID), section.isSectionVisible else { return nil }
    return section.tabs.first { $0.isVisible && $0.kind.isEditorHost }?.id
  }

  /// Returns the editor section nearest to `sectionID` in the requested physical direction.
  /// The recursive Section Layout tree is the sole topology source; no parallel Vim split tree is
  /// maintained.
  func neighboringVimEditorSectionID(
    from sectionID: UUID,
    direction: MainSectionDirection
  ) -> UUID? {
    guard let path = sectionPath(to: sectionID), !path.isEmpty else { return nil }
    let requiredAxis: MainSectionSplitAxis =
      switch direction {
      case .left, .right: .horizontal
      case .up, .down: .vertical
      }
    let movesForward = direction == .right || direction == .down

    var ancestorPath = path
    while let childIndex = ancestorPath.popLast() {
      guard let ancestor = node(at: ancestorPath),
        ancestor.type == .split,
        ancestor.splitAxis == requiredAxis
      else { continue }

      let siblingIndices: [Int]
      if movesForward {
        siblingIndices = Array((childIndex + 1)..<ancestor.children.count)
      } else if childIndex > 0 {
        siblingIndices = Array(stride(from: childIndex - 1, through: 0, by: -1))
      } else {
        siblingIndices = []
      }

      for siblingIndex in siblingIndices {
        let candidates = ancestor.children[siblingIndex].visibleVimEditorSectionIDs
        if let candidate = movesForward ? candidates.first : candidates.last {
          return candidate
        }
      }
    }
    return nil
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

  private func sectionPath(to sectionID: UUID) -> [Int]? {
    switch type {
    case .section:
      return id == sectionID ? [] : nil
    case .split:
      for index in children.indices {
        if let childPath = children[index].sectionPath(to: sectionID) {
          return [index] + childPath
        }
      }
      return nil
    }
  }

  private func node(at path: [Int]) -> MainSectionLayoutNode? {
    guard let first = path.first else { return self }
    guard type == .split, children.indices.contains(first) else { return nil }
    return children[first].node(at: Array(path.dropFirst()))
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
      // Keep the new divider inside the target section. Inserting it into a matching ancestor
      // split makes AppKit redistribute every sibling in that split, including unrelated panes.
      let original = self
      let ordered = placement == .before ? [newSection, original] : [original, newSection]
      self = .split(axis, children: ordered)
      return true

    case .split:
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

/// Serializable window-local copy of a sectional layout. The workspace layout file remains the
/// fallback for newly created windows, while session restoration can reapply the exact layout that
/// belonged to each individual window.
nonisolated struct MainSectionalLayoutSnapshot: Codable, Equatable, Sendable {
  var root: MainSectionLayoutNode
  var splitGeometries: [UUID: MainSectionSplitGeometry]
  var activeLayoutProfileID: UUID?
  var activeSectionID: UUID?
}

@MainActor
final class MainSectionalLayoutController: ObservableObject {
  @Published private(set) var root: MainSectionLayoutNode
  @Published var isCustomizing = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var swapSourceSectionID: UUID?
  @Published private(set) var activeSectionID: UUID?
  @Published private(set) var splitGeometries: [UUID: MainSectionSplitGeometry]
  @Published private(set) var layoutProfiles: [CalciteLayoutProfile]
  @Published private(set) var activeLayoutProfileID: UUID?

  private struct PersistedState: Codable {
    var version: Int
    var root: MainSectionLayoutNode
    var splitGeometries: [UUID: MainSectionSplitGeometry]
    var activeLayoutProfileID: UUID?
    var activeSectionID: UUID?
  }

  private struct LayoutSnapshot {
    var root: MainSectionLayoutNode
    var splitGeometries: [UUID: MainSectionSplitGeometry]
    var activeLayoutProfileID: UUID?
    var activeSectionID: UUID?
  }

  private let workspaceURL: URL
  private let defaults: UserDefaults
  private let usesFileStorage: Bool
  private let includesSidebarByDefault: Bool
  private let profileStore: CalciteLayoutProfileStore
  private var undoStack: [LayoutSnapshot] = []
  private var redoStack: [LayoutSnapshot] = []
  private var persistenceWorkItem: DispatchWorkItem?
  private var hasPendingPersistence = false
  private var writesWorkspaceFallback = true

  init(
    workspaceURL: URL,
    defaults: UserDefaults = .standard,
    includesPanelByDefault _: Bool = false,
    includesSidebarByDefault: Bool = true
  ) {
    let legacyWorkspaceURL = workspaceURL.standardizedFileURL
    let canonicalWorkspaceURL = legacyWorkspaceURL.resolvingSymlinksInPath().standardizedFileURL
    self.workspaceURL = canonicalWorkspaceURL
    self.defaults = defaults
    self.usesFileStorage = defaults === UserDefaults.standard
    self.includesSidebarByDefault = includesSidebarByDefault
    let profileStore = CalciteLayoutProfileStore(defaults: defaults)
    self.profileStore = profileStore

    let persisted = Self.loadState(
      workspaceURL: canonicalWorkspaceURL,
      legacyWorkspaceURL: legacyWorkspaceURL,
      defaults: defaults
    )
    let initialRoot =
      persisted?.root
      ?? Self.makePreset(.standard, includesSidebar: includesSidebarByDefault)
    self.root = initialRoot
    self.splitGeometries = persisted?.splitGeometries ?? [:]
    self.activeLayoutProfileID = persisted?.activeLayoutProfileID
    self.layoutProfiles =
      Self.builtInProfiles(includesSidebar: includesSidebarByDefault)
      + profileStore.loadCustomProfiles()
    self.activeSectionID = persisted?.activeSectionID
    reconcileSplitGeometries()
    if activeLayoutProfileID.flatMap({ id in layoutProfiles.first(where: { $0.id == id }) }) == nil
    {
      activeLayoutProfileID = nil
    }
    if activeSectionID.flatMap({ root.sectionNode(id: $0) })?.hasVisibleContent != true {
      self.activeSectionID =
        root.sectionNodes.first {
          $0.hasVisibleContent && ($0.contains(kind: .workspace) || $0.contains(kind: .editor))
        }?.id
        ?? root.visibleSectionIDs.first
        ?? root.firstSectionID()
    }
  }

  isolated deinit {
    persistenceWorkItem?.cancel()
    if writesWorkspaceFallback, hasPendingPersistence { persistImmediately() }
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

  func splitFractions(
    for splitID: UUID,
    visibleChildIDs: [UUID],
    configurationID: String? = nil,
    defaultSecondaryFraction: Double?
  ) -> [Double] {
    let fallback = Self.defaultFractions(
      childCount: visibleChildIDs.count,
      secondaryFraction: defaultSecondaryFraction
    )
    return splitGeometries[splitID]?.resolvedFractions(
      for: visibleChildIDs,
      configurationID: configurationID,
      fallback: fallback
    ) ?? fallback
  }

  /// Commits one completed divider drag. Interactive split resizing stays entirely inside AppKit;
  /// the controller only receives the final preferred geometry once the drag transaction ends.
  func updateSplitFractions(
    splitID: UUID,
    visibleChildIDs: [UUID],
    configurationID: String? = nil,
    fractions: [Double]
  ) {
    guard visibleChildIDs.count == fractions.count, !visibleChildIDs.isEmpty else { return }
    var geometry = splitGeometries[splitID] ?? MainSectionSplitGeometry(splitID: splitID)
    let previousGeometry = geometry
    geometry.update(
      childIDs: visibleChildIDs,
      fractions: fractions,
      configurationID: configurationID
    )
    guard geometry != previousGeometry else { return }

    let before = currentSnapshot()
    splitGeometries[splitID] = geometry
    undoStack.append(before)
    if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
    redoStack.removeAll(keepingCapacity: true)
    refreshHistoryAvailability()
    scheduleGeometryPersistence()
  }

  var activeLayoutProfile: CalciteLayoutProfile? {
    activeLayoutProfileID.flatMap { id in layoutProfiles.first(where: { $0.id == id }) }
  }

  var isActiveLayoutProfileModified: Bool {
    guard let profile = activeLayoutProfile else { return false }
    return profile.root != root || profile.splitGeometry != splitGeometries
  }

  @discardableResult
  func saveCurrentLayoutProfile(named name: String? = nil) -> UUID {
    let profileName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName =
      profileName.flatMap { $0.isEmpty ? nil : $0 }
      ?? nextCustomProfileName()
    let profile = CalciteLayoutProfile(
      name: resolvedName,
      root: root,
      splitGeometry: splitGeometries,
      sidebarVisible: root.contains(kind: .sidebar, visibleOnly: true)
    )
    layoutProfiles.append(profile)
    activeLayoutProfileID = profile.id
    persistCustomProfiles()
    persist()
    return profile.id
  }

  func updateActiveLayoutProfile() {
    guard let activeLayoutProfileID,
      let index = layoutProfiles.firstIndex(where: { $0.id == activeLayoutProfileID }),
      !layoutProfiles[index].isBuiltIn
    else { return }
    layoutProfiles[index].root = root
    layoutProfiles[index].splitGeometry = splitGeometries
    layoutProfiles[index].sidebarVisible = root.contains(kind: .sidebar, visibleOnly: true)
    persistCustomProfiles()
    persist()
  }

  func renameLayoutProfile(id: UUID, to name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      let index = layoutProfiles.firstIndex(where: { $0.id == id }),
      !layoutProfiles[index].isBuiltIn
    else { return }
    layoutProfiles[index].name = name
    persistCustomProfiles()
  }

  @discardableResult
  func duplicateLayoutProfile(id: UUID) -> UUID? {
    guard var profile = layoutProfiles.first(where: { $0.id == id }) else { return nil }
    profile.id = UUID()
    profile.name = uniqueProfileName(base: "\(profile.name) Copy")
    profile.builtInPreset = nil
    layoutProfiles.append(profile)
    activeLayoutProfileID = profile.id
    persistCustomProfiles()
    persist()
    return profile.id
  }

  func deleteLayoutProfile(id: UUID) {
    guard let profile = layoutProfiles.first(where: { $0.id == id }), !profile.isBuiltIn else {
      return
    }
    layoutProfiles.removeAll { $0.id == id }
    if activeLayoutProfileID == id { activeLayoutProfileID = nil }
    persistCustomProfiles()
    persist()
  }

  func applyLayoutProfile(id: UUID) {
    guard let profile = layoutProfiles.first(where: { $0.id == id }) else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    root = profile.root.normalized()
    splitGeometries = profile.splitGeometry
    activeLayoutProfileID = profile.id
    reconcileSplitGeometries()
    clearInvalidSelections()
    persist()
    refreshHistoryAvailability()
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
    guard root.sectionNode(id: id)?.hasVisibleContent == true else { return }
    guard activeSectionID != id else { return }
    activeSectionID = id
    persist()
  }

  func captureSnapshot() -> MainSectionalLayoutSnapshot {
    MainSectionalLayoutSnapshot(
      root: root,
      splitGeometries: splitGeometries,
      activeLayoutProfileID: activeLayoutProfileID,
      activeSectionID: activeSectionID
    )
  }

  func restoreSnapshot(
    _ snapshot: MainSectionalLayoutSnapshot,
    persistWorkspaceFallback: Bool = true
  ) {
    let normalizedRoot = snapshot.root.normalized()
    guard normalizedRoot.leafCount > 0 else { return }
    root = normalizedRoot
    splitGeometries = snapshot.splitGeometries
    activeLayoutProfileID = snapshot.activeLayoutProfileID
    activeSectionID = snapshot.activeSectionID
    reconcileSplitGeometries()
    clearInvalidSelections()
    if activeLayoutProfileID.flatMap({ id in layoutProfiles.first(where: { $0.id == id }) }) == nil
    {
      activeLayoutProfileID = nil
    }
    if activeSectionID == nil { activeSectionID = preferredVisibleSectionID() }
    undoStack.removeAll(keepingCapacity: false)
    redoStack.removeAll(keepingCapacity: false)
    refreshHistoryAvailability()
    if persistWorkspaceFallback {
      writesWorkspaceFallback = true
      persist()
    } else {
      // A restored window owns its layout through the window-session snapshot. It must never
      // overwrite the workspace fallback merely because focus, tabs, or dividers change later.
      persistenceWorkItem?.cancel()
      persistenceWorkItem = nil
      hasPendingPersistence = false
      writesWorkspaceFallback = false
    }
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
    if isVisible, root.sectionNode(id: sectionID)?.hasVisibleContent == true {
      activeSectionID = sectionID
    } else if activeSectionID == sectionID {
      activeSectionID = preferredVisibleSectionID()
    }
    persist()
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
      self.activeSectionID = preferredVisibleSectionID()
    }
    persist()
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
    persist()
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
    persist()
    return sectionID
  }

  /// Activates a Vim-capable section and selects its editor-host tab.
  @discardableResult
  func activateVimEditorSection(_ sectionID: UUID) -> UUID? {
    guard let tabID = root.vimEditorTabID(in: sectionID) else { return nil }
    selectTab(sectionID: sectionID, tabID: tabID)
    activeSectionID = sectionID
    return tabID
  }

  /// Cycles only through sections that contain a visible editor host. Utility-only sections do
  /// not participate in Vim's `<C-W>w` / `<C-W>W` window order.
  @discardableResult
  func navigateVimEditorSection(forward: Bool) -> UUID? {
    let sectionIDs = root.visibleVimEditorSectionIDs
    guard !sectionIDs.isEmpty else { return nil }
    let currentIndex =
      activeSectionID.flatMap { sectionIDs.firstIndex(of: $0) }
      ?? (forward ? -1 : 0)
    let nextIndex =
      forward
      ? (currentIndex + 1) % sectionIDs.count
      : (currentIndex - 1 + sectionIDs.count) % sectionIDs.count
    let sectionID = sectionIDs[nextIndex]
    _ = activateVimEditorSection(sectionID)
    return sectionID
  }

  /// Navigates the persisted Section Layout split tree instead of maintaining a second Vim
  /// topology model.
  @discardableResult
  func navigateVimEditorSection(direction: MainSectionDirection) -> UUID? {
    guard let activeSectionID,
      let sectionID = root.neighboringVimEditorSectionID(
        from: activeSectionID,
        direction: direction
      )
    else { return nil }
    _ = activateVimEditorSection(sectionID)
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
      persist()
      return
    }

    mutate { root in root.addTab(sectionID: sectionID, kind: kind) != nil }
    activeSectionID = sectionID
    persist()
  }

  func removeTab(sectionID: UUID, tabID: UUID) {
    mutate { $0.removeTab(sectionID: sectionID, tabID: tabID) }
  }

  func replaceTab(sectionID: UUID, tabID: UUID, with kind: MainSectionKind) {
    mutate { $0.replaceTab(sectionID: sectionID, tabID: tabID, with: kind) }
    activeSectionID = sectionID
    persist()
  }

  func replaceSection(id: UUID, with kind: MainSectionKind) {
    mutate { $0.replaceSection(id: id, with: kind) }
    activeSectionID = id
    persist()
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

  /// Creates a new editor section through Calcite's persisted Section Layout and returns both
  /// identities needed to bind a Vim editor window immediately.
  @discardableResult
  func splitVimEditorSection(
    id sectionID: UUID,
    axis: MainSectionSplitAxis,
    placement: MainSectionPlacement = .after
  ) -> (sectionID: UUID, editorTabID: UUID)? {
    guard root.vimEditorTabID(in: sectionID) != nil else { return nil }
    let newSectionID = UUID()
    let editorTab = MainSectionTab(kind: .editor)
    let newSection = MainSectionLayoutNode.section(
      tabs: [editorTab],
      selectedTabID: editorTab.id,
      id: newSectionID
    )
    var updated = root
    guard
      updated.splitSection(
        id: sectionID,
        axis: axis,
        newSection: newSection,
        placement: placement
      )
    else { return nil }
    commit(updated.normalized())
    activeSectionID = newSectionID
    persist()
    return (newSectionID, editorTab.id)
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
    persist()
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
      persist()
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
      persist()
      return
    }

    guard let target = preferredSectionID else { return }
    addTab(to: target, kind: kind)
  }

  func applyPreset(_ preset: MainSectionalLayoutPreset) {
    if let profile = layoutProfiles.first(where: { $0.builtInPreset == preset }) {
      applyLayoutProfile(id: profile.id)
    } else {
      commit(Self.makePreset(preset, includesSidebar: includesSidebarByDefault))
    }
  }

  func reset() {
    applyPreset(.standard)
  }

  func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(currentSnapshot())
    restore(previous)
    persist()
    refreshHistoryAvailability()
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(currentSnapshot())
    restore(next)
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

  private func preferredVisibleSectionID() -> UUID? {
    root.sectionNodes.first { section in
      section.hasVisibleContent
        && (section.contains(kind: .workspace) || section.contains(kind: .editor))
    }?.id
      ?? root.visibleSectionIDs.first
      ?? root.firstSectionID()
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
    case .sidebar, .symbols, .settings, .themeBuilder, .problems, .buildOutput, .debug, .empty:
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
    let normalized = updated.normalized()
    splitGeometries = Self.migratedGeometries(
      from: root,
      geometries: splitGeometries,
      to: normalized
    )
    root = normalized
    reconcileSplitGeometries()
    clearInvalidSelections()
    persist()
  }

  private func commit(_ updated: MainSectionLayoutNode) {
    let normalized = updated.normalized()
    guard normalized != root else { return }
    pushUndoSnapshot()
    redoStack.removeAll(keepingCapacity: true)
    splitGeometries = Self.migratedGeometries(
      from: root,
      geometries: splitGeometries,
      to: normalized
    )
    root = normalized
    reconcileSplitGeometries()
    clearInvalidSelections()
    persist()
    refreshHistoryAvailability()
  }

  private func currentSnapshot() -> LayoutSnapshot {
    LayoutSnapshot(
      root: root,
      splitGeometries: splitGeometries,
      activeLayoutProfileID: activeLayoutProfileID,
      activeSectionID: activeSectionID
    )
  }

  private func restore(_ snapshot: LayoutSnapshot) {
    root = snapshot.root.normalized()
    splitGeometries = snapshot.splitGeometries
    activeLayoutProfileID = snapshot.activeLayoutProfileID
    activeSectionID = snapshot.activeSectionID
    reconcileSplitGeometries()
    clearInvalidSelections()
  }

  private func pushUndoSnapshot() {
    undoStack.append(currentSnapshot())
    if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
  }

  private func reconcileSplitGeometries() {
    let validSplitIDs = Set(root.splitNodes.map(\.id))
    splitGeometries = splitGeometries.filter { validSplitIDs.contains($0.key) }

    for split in root.splitNodes {
      let childIDs = split.children.map(\.id)
      let fallback = Self.defaultFractions(for: split)
      var geometry =
        splitGeometries[split.id]
        ?? MainSectionSplitGeometry(splitID: split.id)
      geometry.reconcile(with: childIDs, fallback: fallback)
      geometry.collapsedChildIDs = Set(
        split.children.compactMap { child in child.hasVisibleContent ? nil : child.id }
      )
      splitGeometries[split.id] = geometry
    }
  }

  private func persistCustomProfiles() {
    profileStore.saveCustomProfiles(layoutProfiles.filter { !$0.isBuiltIn })
  }

  private func nextCustomProfileName() -> String {
    var number = 1
    while layoutProfiles.contains(where: { $0.name == "Custom Layout \(number)" }) {
      number += 1
    }
    return "Custom Layout \(number)"
  }

  private func uniqueProfileName(base: String) -> String {
    guard layoutProfiles.contains(where: { $0.name == base }) else { return base }
    var number = 2
    while layoutProfiles.contains(where: { $0.name == "\(base) \(number)" }) {
      number += 1
    }
    return "\(base) \(number)"
  }

  private func clearInvalidSelections() {
    if let swapSourceSectionID, !root.containsSection(swapSourceSectionID) {
      self.swapSourceSectionID = nil
    }
    if let activeSectionID,
      !root.containsSection(activeSectionID)
        || root.sectionNode(id: activeSectionID)?.hasVisibleContent != true
    {
      self.activeSectionID = preferredVisibleSectionID()
    }
  }

  /// Persists structural changes immediately. Any pending geometry-only save is folded into the
  /// same atomic write so a delayed divider transaction can never overwrite newer state.
  private func persist() {
    persistenceWorkItem?.cancel()
    persistenceWorkItem = nil
    hasPendingPersistence = false
    guard writesWorkspaceFallback else { return }
    persistImmediately()
  }

  private func scheduleGeometryPersistence() {
    guard writesWorkspaceFallback else { return }
    // XCTest and alternate defaults stores expect synchronous visibility of writes. Production
    // file storage is debounced because divider transactions can occur in quick succession.
    guard usesFileStorage else {
      persist()
      return
    }
    persistenceWorkItem?.cancel()
    hasPendingPersistence = true
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.persistenceWorkItem = nil
        guard self.hasPendingPersistence else { return }
        self.hasPendingPersistence = false
        self.persistImmediately()
      }
    }
    persistenceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
  }

  func flushPendingPersistence() {
    persistenceWorkItem?.cancel()
    persistenceWorkItem = nil
    guard writesWorkspaceFallback, hasPendingPersistence else {
      hasPendingPersistence = false
      return
    }
    hasPendingPersistence = false
    persistImmediately()
  }

  private func persistImmediately() {
    let state = PersistedState(
      version: 4,
      root: root,
      splitGeometries: splitGeometries,
      activeLayoutProfileID: activeLayoutProfileID,
      activeSectionID: activeSectionID
    )
    if usesFileStorage {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try? CalciteStateStorage.save(
        state,
        to: CalciteStateStorage.workspaceURL(workspaceURL, filename: "layout.json"),
        encoder: encoder
      )
    } else if let data = try? JSONEncoder().encode(state) {
      defaults.set(data, forKey: Self.storageKey(for: workspaceURL))
    }
  }

  private func refreshHistoryAvailability() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }

  private static func loadState(
    workspaceURL: URL,
    legacyWorkspaceURL: URL,
    defaults: UserDefaults
  ) -> PersistedState? {
    let usesFileStorage = defaults === UserDefaults.standard
    let canonicalKey = storageKey(for: workspaceURL)
    let previousKey = storageKey(for: legacyWorkspaceURL)
    let data: Data?
    if usesFileStorage {
      let fileURL = CalciteStateStorage.workspaceURL(workspaceURL, filename: "layout.json")
      if let state = CalciteStateStorage.load(PersistedState.self, from: fileURL),
        state.root.leafCount > 0
      {
        return normalizedState(state)
      }
      let previousFileURL = CalciteStateStorage.workspaceURL(
        legacyWorkspaceURL,
        filename: "layout.json"
      )
      if previousFileURL != fileURL,
        let state = CalciteStateStorage.load(PersistedState.self, from: previousFileURL),
        state.root.leafCount > 0
      {
        let normalized = normalizedState(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? CalciteStateStorage.save(normalized, to: fileURL, encoder: encoder)
        try? CalciteStateStorage.remove(at: previousFileURL)
        return normalized
      }
      data =
        defaults.data(forKey: canonicalKey)
        ?? (previousKey == canonicalKey ? nil : defaults.data(forKey: previousKey))
    } else {
      data =
        defaults.data(forKey: canonicalKey)
        ?? (previousKey == canonicalKey ? nil : defaults.data(forKey: previousKey))
    }

    guard let data else { return nil }
    let migrated: PersistedState?
    if let state = try? JSONDecoder().decode(PersistedState.self, from: data),
      state.root.leafCount > 0
    {
      migrated = normalizedState(state)
    } else if let root = try? JSONDecoder().decode(MainSectionLayoutNode.self, from: data),
      root.leafCount > 0
    {
      migrated = PersistedState(
        version: 4,
        root: root.normalized(),
        splitGeometries: [:],
        activeLayoutProfileID: nil,
        activeSectionID: nil
      )
    } else {
      migrated = nil
    }

    if usesFileStorage, let migrated {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try? CalciteStateStorage.save(
        migrated,
        to: CalciteStateStorage.workspaceURL(workspaceURL, filename: "layout.json"),
        encoder: encoder
      )
      defaults.removeObject(forKey: canonicalKey)
      if previousKey != canonicalKey { defaults.removeObject(forKey: previousKey) }
    }
    return migrated
  }

  private static func normalizedState(_ state: PersistedState) -> PersistedState {
    let root = state.root.normalized()
    let activeSectionID = state.activeSectionID.flatMap { id in
      root.sectionNode(id: id)?.hasVisibleContent == true ? id : nil
    }
    return PersistedState(
      version: max(4, state.version),
      root: root,
      splitGeometries: state.splitGeometries,
      activeLayoutProfileID: state.activeLayoutProfileID,
      activeSectionID: activeSectionID
    )
  }

  private static func storageKey(for workspaceURL: URL) -> String {
    let path = workspaceURL.standardizedFileURL.path
    let encodedPath = Data(path.utf8).base64EncodedString()
    return "Calcite.mainSectionalLayout.\(encodedPath)"
  }

  private static func defaultFractions(
    childCount: Int,
    secondaryFraction: Double? = nil
  ) -> [Double] {
    guard childCount > 0 else { return [] }
    if childCount == 2, let secondaryFraction {
      let secondary = min(max(secondaryFraction, 0.08), 0.92)
      return [1 - secondary, secondary]
    }
    return Array(repeating: 1 / Double(childCount), count: childCount)
  }

  private static func defaultFractions(for split: MainSectionLayoutNode) -> [Double] {
    guard split.type == .split else { return [] }
    if split.children.count == 2 {
      if split.splitAxis == .vertical,
        split.children[1].sectionKinds.contains(where: {
          $0.isBottomPanelKind || $0 == .debug
        })
      {
        return defaultFractions(childCount: 2, secondaryFraction: 0.22)
      }
      if split.splitAxis == .horizontal, split.children[0].contains(kind: .sidebar) {
        return [0.22, 0.78]
      }
    }
    return defaultFractions(childCount: split.children.count)
  }

  private static func geometryMap(
    for root: MainSectionLayoutNode
  ) -> [UUID: MainSectionSplitGeometry] {
    Dictionary(
      uniqueKeysWithValues: root.splitNodes.map { split in
        let childIDs = split.children.map(\.id)
        let fractions = defaultFractions(for: split)
        return (
          split.id,
          MainSectionSplitGeometry(
            splitID: split.id,
            childFractions: Dictionary(uniqueKeysWithValues: zip(childIDs, fractions)),
            collapsedChildIDs: []
          )
        )
      })
  }

  /// Carries divider fractions across topology edits. Fractions are first matched by descendant
  /// section identity, so wrapping a section in a new split or collapsing a split back to one
  /// child does not resize its siblings. Newly inserted siblings divide only the nearest matched
  /// child's existing share; removed children donate their share to the nearest survivor.
  private static func migratedGeometries(
    from oldRoot: MainSectionLayoutNode,
    geometries oldGeometries: [UUID: MainSectionSplitGeometry],
    to newRoot: MainSectionLayoutNode
  ) -> [UUID: MainSectionSplitGeometry] {
    let oldSplits = Dictionary(uniqueKeysWithValues: oldRoot.splitNodes.map { ($0.id, $0) })
    var result: [UUID: MainSectionSplitGeometry] = [:]

    for newSplit in newRoot.splitNodes {
      let newChildIDs = newSplit.children.map(\.id)
      guard let oldSplit = oldSplits[newSplit.id] else {
        var geometry = MainSectionSplitGeometry(splitID: newSplit.id)
        geometry.update(childIDs: newChildIDs, fractions: defaultFractions(for: newSplit))
        result[newSplit.id] = geometry
        continue
      }

      let oldChildIDs = oldSplit.children.map(\.id)
      let oldFractions =
        oldGeometries[newSplit.id]?.resolvedFractions(
          for: oldChildIDs,
          fallback: defaultFractions(for: oldSplit)
        ) ?? defaultFractions(for: oldSplit)
      let oldSectionSets = oldSplit.children.map { Set($0.sectionNodes.map(\.id)) }
      let newSectionSets = newSplit.children.map { Set($0.sectionNodes.map(\.id)) }
      var allocations = Array(repeating: 0.0, count: newSplit.children.count)

      for oldIndex in oldSplit.children.indices {
        let matches = newSplit.children.indices.filter {
          !oldSectionSets[oldIndex].isDisjoint(with: newSectionSets[$0])
        }
        guard !matches.isEmpty else { continue }
        let share = oldFractions[oldIndex] / Double(matches.count)
        for newIndex in matches {
          allocations[newIndex] += share
        }
      }

      // A removed child gives its old space to the nearest remaining child rather than forcing a
      // full equal-size reset of the split.
      for oldIndex in oldSplit.children.indices
      where newSplit.children.indices.allSatisfy({
        oldSectionSets[oldIndex].isDisjoint(with: newSectionSets[$0])
      }) {
        guard !allocations.isEmpty else { continue }
        let target =
          allocations.indices.min { lhs, rhs in
            abs(lhs - oldIndex) < abs(rhs - oldIndex)
          } ?? 0
        allocations[target] += oldFractions[oldIndex]
      }

      // A directly inserted child has no old descendant identity. Split only the closest
      // survivor's share, which keeps every unrelated divider position stable.
      var cursor = 0
      while cursor < allocations.count {
        guard allocations[cursor] == 0 else {
          cursor += 1
          continue
        }
        let start = cursor
        while cursor < allocations.count, allocations[cursor] == 0 { cursor += 1 }
        let end = cursor
        let candidates = allocations.indices.filter { allocations[$0] > 0 }
        guard
          let donor = candidates.min(by: { lhs, rhs in
            let lhsDistance = min(abs(lhs - start), abs(lhs - (end - 1)))
            let rhsDistance = min(abs(rhs - start), abs(rhs - (end - 1)))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs < rhs
          })
        else {
          allocations = defaultFractions(for: newSplit)
          break
        }
        let insertedCount = end - start
        let share = allocations[donor] / Double(insertedCount + 1)
        allocations[donor] = share
        for index in start..<end { allocations[index] = share }
      }

      var geometry = oldGeometries[newSplit.id] ?? MainSectionSplitGeometry(splitID: newSplit.id)
      geometry.update(childIDs: newChildIDs, fractions: allocations)
      result[newSplit.id] = geometry
    }
    return result
  }

  private static func builtInProfiles(
    includesSidebar: Bool
  ) -> [CalciteLayoutProfile] {
    let identifiers: [MainSectionalLayoutPreset: UUID] = [
      .standard: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
      .editorFocus: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
      .sideBySide: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
      .debugging: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
    ]
    return MainSectionalLayoutPreset.allCases.map { preset in
      let root = makePreset(preset, includesSidebar: includesSidebar)
      return CalciteLayoutProfile(
        id: identifiers[preset]!,
        name: preset.title,
        root: root,
        splitGeometry: geometryMap(for: root),
        sidebarVisible: root.contains(kind: .sidebar, visibleOnly: true),
        builtInPreset: preset
      )
    }
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
