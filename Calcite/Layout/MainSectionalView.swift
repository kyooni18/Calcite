import AppKit
import EditorVim
import SwiftUI

/// Backend-driven workbench whose sections contain independently persisted content tabs.
@MainActor
struct MainSectionalView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject private var layout: MainSectionalLayoutController

  init(
    backend: CalciteBackend,
    windowSession: CalciteBackendWindowSession
  ) {
    precondition(
      windowSession.backend === backend,
      "The window session must belong to the supplied CalciteBackend."
    )
    self.backend = backend
    self.windowSession = windowSession
    self.layout = windowSession.sectionalLayout
  }

  var body: some View {
    MainSectionLayoutNodeView(
      node: layout.root,
      backend: backend,
      windowSession: windowSession,
      layout: layout,
      parentSplitAxis: nil
    )
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    .background(backend.controller.profile.workbench.windowBackground.color)
    .background {
      MainSectionKeyboardNavigationMonitor(
        navigateTab: { windowSession.navigateTab(forward: $0) },
        selectTab: { windowSession.selectTab(number: $0) },
        navigateSection: { windowSession.navigateSection(forward: $0) },
        navigateSectionDirection: { windowSession.commandNavigateSection(direction: $0) },
        handleHostRequest: backend.handleVimHostRequest
      )
    }
    .onAppear {
      windowSession.markActive()
      synchronizeSidebarVisibility()
      reconcileSectionalEditorAssignments()
    }
    .onChange(of: layout.root) { _, _ in
      synchronizeSidebarVisibility()
      reconcileSectionalEditorAssignments()
    }
  }

  private func reconcileSectionalEditorAssignments() {
    windowSession.reconcileSectionalEditorAssignments(
      validSectionIDs: Set(
        layout.root.tabIDs(kind: .editor) + layout.root.tabIDs(kind: .workspace)
      )
    )
  }

  private func synchronizeSidebarVisibility() {
    let isConfiguredVisible = layout.root.sectionNodes.contains { section in
      section.tabs.contains { $0.kind == .sidebar && $0.isVisible }
    }
    if windowSession.showsSidebar != isConfiguredVisible {
      windowSession.showsSidebar = isConfiguredVisible
    }
  }
}

@MainActor
private struct MainSectionKeyboardNavigationMonitor: NSViewRepresentable {
  let navigateTab: (Bool) -> Void
  let selectTab: (Int) -> Void
  let navigateSection: (Bool) -> Void
  let navigateSectionDirection: (MainSectionDirection) -> Void
  let handleHostRequest: (VimHostRequest) -> Void

  func makeNSView(context: Context) -> MainSectionKeyboardNavigationView {
    MainSectionKeyboardNavigationView(
      navigateTab: navigateTab,
      selectTab: selectTab,
      navigateSection: navigateSection,
      navigateSectionDirection: navigateSectionDirection,
      handleHostRequest: handleHostRequest
    )
  }

  func updateNSView(
    _ nsView: MainSectionKeyboardNavigationView,
    context: Context
  ) {
    nsView.navigateTab = navigateTab
    nsView.selectTab = selectTab
    nsView.navigateSection = navigateSection
    nsView.navigateSectionDirection = navigateSectionDirection
    nsView.handleHostRequest = handleHostRequest
  }
}

@MainActor
private final class MainSectionKeyboardNavigationView: NSView {
  var navigateTab: (Bool) -> Void
  var selectTab: (Int) -> Void
  var navigateSection: (Bool) -> Void
  var navigateSectionDirection: (MainSectionDirection) -> Void
  var handleHostRequest: (VimHostRequest) -> Void
  private var keyMonitor: Any?
  private var isAwaitingLeader = false

  init(
    navigateTab: @escaping (Bool) -> Void,
    selectTab: @escaping (Int) -> Void,
    navigateSection: @escaping (Bool) -> Void,
    navigateSectionDirection: @escaping (MainSectionDirection) -> Void,
    handleHostRequest: @escaping (VimHostRequest) -> Void
  ) {
    self.navigateTab = navigateTab
    self.selectTab = selectTab
    self.navigateSection = navigateSection
    self.navigateSectionDirection = navigateSectionDirection
    self.handleHostRequest = handleHostRequest
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installMonitorIfNeeded()
  }

  private func installMonitorIfNeeded() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      // Native editors already process their own Vim keymaps, and the terminal
      // has its separate backslash leader. Everywhere else in the workbench,
      // Space acts as Calcite's global leader.
      if event.window?.firstResponder is NSTextView || event.window?.firstResponder is NSTextField {
        self.isAwaitingLeader = false
        return event
      }
      let modifiers = event.modifierFlags.intersection([
        .command, .option, .control, .shift,
      ])
      if self.isAwaitingLeader {
        self.isAwaitingLeader = false
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
          self.handleLeaderMapping(key)
        {
          return nil
        }
        return event
      }
      if modifiers.isEmpty, event.characters == " " {
        self.isAwaitingLeader = true
        return nil
      }
      if event.keyCode == 48, modifiers == [.control] {
        self.navigateTab(true)
        return nil
      }
      if event.keyCode == 48, modifiers == [.control, .shift] {
        self.navigateTab(false)
        return nil
      }
      if modifiers == [.command], let characters = event.charactersIgnoringModifiers,
        let number = Int(characters), (1...9).contains(number)
      {
        self.selectTab(number)
        return nil
      }
      if event.keyCode == 124, modifiers == [.command, .option] {
        self.navigateSectionDirection(.right)
        return nil
      }
      if event.keyCode == 123, modifiers == [.command, .option] {
        self.navigateSectionDirection(.left)
        return nil
      }
      if event.keyCode == 126, modifiers == [.command, .option] {
        self.navigateSectionDirection(.up)
        return nil
      }
      if event.keyCode == 125, modifiers == [.command, .option] {
        self.navigateSectionDirection(.down)
        return nil
      }
      return event
    }
  }

  private func handleLeaderMapping(_ key: String) -> Bool {
    switch key {
    case "h": navigateSectionDirection(.left)
    case "j": navigateSectionDirection(.down)
    case "k": navigateSectionDirection(.up)
    case "l": navigateSectionDirection(.right)
    case ",": navigateTab(false)
    case ".": navigateTab(true)
    case "1"..."9":
      guard let number = Int(key) else { return false }
      selectTab(number)
    case "w": handleHostRequest(.write)
    case "b": handleHostRequest(.custom("build"))
    case "r": handleHostRequest(.custom("run"))
    case "t": handleHostRequest(.custom("terminal"))
    case "e": handleHostRequest(.custom("sidebar"))
    case "f": handleHostRequest(.format)
    case "s": handleHostRequest(.custom("find"))
    default: return false
    }
    return true
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    super.viewWillMove(toWindow: newWindow)
  }
}

@MainActor
private struct MainSectionLayoutNodeView: View {
  let node: MainSectionLayoutNode
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject var layout: MainSectionalLayoutController
  let parentSplitAxis: MainSectionSplitAxis?

  @ViewBuilder
  var body: some View {
    if shouldRender {
      switch node.type {
      case .section:
        MainSectionLeafView(
          node: node,
          backend: backend,
          windowSession: windowSession,
          layout: layout,
          parentSplitAxis: parentSplitAxis
        )
        .id(node.id)
      case .split:
        splitView.id(node.id)
      }
    }
  }

  private var shouldRender: Bool {
    switch node.type {
    case .section:
      node.hasVisibleContent || node.isFastPanel
    case .split:
      node.children.contains { child in
        child.hasVisibleContent || child.fastPanelSectionIDs.isEmpty == false
      }
    }
  }

  private var visibleChildren: [MainSectionLayoutNode] {
    node.children.filter { child in
      child.hasVisibleContent || child.fastPanelSectionIDs.isEmpty == false
    }
  }

  @ViewBuilder
  private var splitView: some View {
    if visibleChildren.isEmpty {
      EmptyView()
    } else {
      let axis = node.splitAxis ?? .horizontal
      let childIDs = visibleChildren.map(\.id)
      let configurationID = node.geometryVisibilitySignature(visibleOnly: true)
      let defaultSecondaryFraction = windowSession.layoutProfile.defaultSecondaryFraction(
        for: node.splitAxis,
        childCount: visibleChildren.count
      )
      let fractions = layout.splitFractions(
        for: node.id,
        visibleChildIDs: childIDs,
        configurationID: configurationID,
        defaultSecondaryFraction: defaultSecondaryFraction.map { Double($0) }
      )
      let children = visibleChildren.map { child in
        MainSectionOwnedSplitChild(
          id: child.id,
          content: AnyView(
            MainSectionLayoutNodeView(
              node: child,
              backend: backend,
              windowSession: windowSession,
              layout: layout,
              parentSplitAxis: axis
            )
            .id(child.id)
          ),
          minimumThickness: child.minimumThickness(in: axis),
          holdingPriority: child.splitHoldingPriority
        )
      }

      // Keep the split host alive even with a single visible child. Removing the wrapper used to
      // destroy and recreate the editor NSTextView whenever a sidebar/fast panel was toggled.
      MainSectionOwnedSplitView(
        splitID: node.id,
        axis: axis,
        configurationID: configurationID,
        children: children,
        preferredFractions: fractions,
        onPreferredFractionsChanged: { changedFractions in
          layout.updateSplitFractions(
            splitID: node.id,
            visibleChildIDs: childIDs,
            configurationID: configurationID,
            fractions: changedFractions
          )
        }
      )
    }
  }

}

extension MainSectionLayoutNode {
  fileprivate func minimumThickness(in parentAxis: MainSectionSplitAxis) -> CGFloat {
    switch type {
    case .section:
      guard hasVisibleContent else {
        return parentAxis == .horizontal ? 28 : 24
      }
      let kinds = visibleTabs.map(\.kind)
      switch parentAxis {
      case .horizontal:
        return CGFloat(kinds.map(\.minimumWidth).max() ?? MainSectionKind.empty.minimumWidth)
      case .vertical:
        return CGFloat(kinds.map(\.minimumHeight).max() ?? MainSectionKind.empty.minimumHeight)
      }

    case .split:
      let renderedChildren = children.filter {
        $0.hasVisibleContent || !$0.fastPanelSectionIDs.isEmpty
      }
      guard !renderedChildren.isEmpty else { return 1 }
      let childMinimums = renderedChildren.map { $0.minimumThickness(in: parentAxis) }
      if splitAxis == parentAxis {
        return childMinimums.reduce(0, +) + CGFloat(max(0, childMinimums.count - 1))
      }
      return childMinimums.max() ?? 1
    }
  }

  fileprivate var splitHoldingPriority: NSLayoutConstraint.Priority {
    if contains(kind: .workspace, visibleOnly: true) || contains(kind: .editor, visibleOnly: true) {
      // Editor/workspace panes intentionally absorb window growth and shrinkage first.
      return NSLayoutConstraint.Priority(rawValue: 250)
    }
    if sectionKinds.contains(.sidebar) || sectionKinds.contains(.symbols) {
      return NSLayoutConstraint.Priority(rawValue: 360)
    }
    if sectionKinds.contains(where: \.isBottomPanelKind) || sectionKinds.contains(.debug) {
      return NSLayoutConstraint.Priority(rawValue: 350)
    }
    if sectionKinds.contains(.settings) || sectionKinds.contains(.themeBuilder) {
      return NSLayoutConstraint.Priority(rawValue: 330)
    }
    return NSLayoutConstraint.Priority(rawValue: 300)
  }
}

/// One split pane hosted by Calcite's AppKit-owned split renderer. `AnyView` is deliberate here:
/// the hosting view remains stable by child UUID while SwiftUI is free to update the pane content.
struct MainSectionOwnedSplitChild {
  let id: UUID
  let content: AnyView
  let minimumThickness: CGFloat
  let holdingPriority: NSLayoutConstraint.Priority
}

/// Owns the actual `NSSplitView` instead of reaching through SwiftUI's `HSplitView` / `VSplitView`
/// implementation. Preferred geometry only crosses the SwiftUI/AppKit boundary for initial restore,
/// explicit profile/undo changes, and one final commit after a user divider drag.
@MainActor
private struct MainSectionOwnedSplitView: NSViewRepresentable {
  let splitID: UUID
  let axis: MainSectionSplitAxis
  let configurationID: String
  let children: [MainSectionOwnedSplitChild]
  let preferredFractions: [Double]
  let onPreferredFractionsChanged: ([Double]) -> Void

  func makeNSView(context: Context) -> MainSectionOwnedNSSplitView {
    let splitView = MainSectionOwnedNSSplitView(frame: .zero)
    splitView.configure(
      splitID: splitID,
      axis: axis,
      configurationID: configurationID,
      children: children,
      preferredFractions: preferredFractions,
      onPreferredFractionsChanged: onPreferredFractionsChanged
    )
    return splitView
  }

  func updateNSView(_ nsView: MainSectionOwnedNSSplitView, context: Context) {
    nsView.configure(
      splitID: splitID,
      axis: axis,
      configurationID: configurationID,
      children: children,
      preferredFractions: preferredFractions,
      onPreferredFractionsChanged: onPreferredFractionsChanged
    )
  }
}

@MainActor
final class MainSectionOwnedNSSplitView: NSSplitView, NSSplitViewDelegate {
  private enum GeometryState: String {
    case uninitialized
    case restoring
    case ready
    case userDragging
  }

  private var splitID = UUID()
  private var axis: MainSectionSplitAxis = .horizontal
  private var configurationID = ""
  private var childIDs: [UUID] = []
  private var hostingViews: [UUID: NSHostingView<AnyView>] = [:]
  private var minimumThicknesses: [CGFloat] = []
  private var modelFractions: [Double] = []
  private var preferredFractions: [Double] = []
  private var lastSubmittedFractions: [Double]?
  private var needsPreferredGeometryApplication = false
  private var isApplyingPreferredGeometry = false
  private var state: GeometryState = .uninitialized
  private var sawWindowLiveResize = false
  private var onPreferredFractionsChanged: ([Double]) -> Void = { _ in }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    dividerStyle = .thin
    arrangesAllSubviews = false
    autosaveName = nil
    delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    splitID: UUID,
    axis: MainSectionSplitAxis,
    configurationID: String,
    children: [MainSectionOwnedSplitChild],
    preferredFractions: [Double],
    onPreferredFractionsChanged: @escaping ([Double]) -> Void
  ) {
    let nextChildIDs = children.map(\.id)
    let topologyChanged =
      self.splitID != splitID || self.axis != axis || childIDs != nextChildIDs
    let geometryConfigurationChanged = self.configurationID != configurationID

    self.splitID = splitID
    self.axis = axis
    self.configurationID = configurationID
    self.onPreferredFractionsChanged = onPreferredFractionsChanged
    isVertical = axis == .horizontal

    if topologyChanged {
      childIDs = nextChildIDs
      reconcileChildren(children)
      minimumThicknesses = children.map(\.minimumThickness)
      applyHoldingPriorities(children)
      let normalized = normalizedFractions(preferredFractions, count: children.count)
      modelFractions = normalized
      self.preferredFractions = normalized
      lastSubmittedFractions = nil
      needsPreferredGeometryApplication = children.count > 1
      state = children.count > 1 ? .restoring : .ready
      log(
        "Split topology installed",
        metadata: ["children": String(children.count), "axis": axis.rawValue]
      )
      needsLayout = true
      applyPreferredGeometryIfPossible()
      return
    }

    updateHostedContent(children)
    minimumThicknesses = children.map(\.minimumThickness)
    applyHoldingPriorities(children)

    let normalizedModel = normalizedFractions(preferredFractions, count: children.count)
    if geometryConfigurationChanged {
      // A fast-panel visibility change can leave the rendered child IDs unchanged. The geometry
      // configuration identity is therefore part of the restore trigger even when the numeric
      // fractions happen to equal the previous state's preferred fractions.
      modelFractions = normalizedModel
      self.preferredFractions = normalizedModel
      lastSubmittedFractions = nil
      needsPreferredGeometryApplication = children.count > 1
      state = children.count > 1 ? .restoring : .ready
      needsLayout = true
      applyPreferredGeometryIfPossible()
      return
    }

    guard !fractionsApproximatelyEqual(normalizedModel, modelFractions) else { return }
    modelFractions = normalizedModel

    if let submitted = lastSubmittedFractions,
      fractionsApproximatelyEqual(normalizedModel, submitted)
    {
      // The AppKit split already has this geometry: this update is the model acknowledging the
      // completed user drag, not a command to move the divider again.
      self.preferredFractions = normalizedModel
      lastSubmittedFractions = nil
      needsPreferredGeometryApplication = false
      state = .ready
      return
    }

    // Undo, redo, profile changes and window-session restoration are authoritative model changes.
    self.preferredFractions = normalizedModel
    needsPreferredGeometryApplication = children.count > 1
    state = children.count > 1 ? .restoring : .ready
    needsLayout = true
    applyPreferredGeometryIfPossible()
  }

  override func layout() {
    super.layout()
    if window?.inLiveResize == true {
      sawWindowLiveResize = true
    }
    applyPreferredGeometryIfPossible()
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    guard sawWindowLiveResize else { return }
    sawWindowLiveResize = false
    restorePreferredGeometryAfterResizeIfPossible()
  }

  func restorePreferredGeometryAfterResizeIfPossible() {
    guard state == .ready, childIDs.count > 1 else { return }
    let availableLength = currentAvailableLength
    guard canSatisfyPreferredGeometry(availableLength: availableLength) else { return }
    // Window resizing is not a user divider edit. Re-apply the user's preferred geometry once,
    // after the resize transaction ends, instead of fighting AppKit on every intermediate frame.
    needsPreferredGeometryApplication = true
    state = .restoring
    applyPreferredGeometryIfPossible()
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let isDividerInteraction = pointIsOnDivider(point)
    if isDividerInteraction {
      state = .userDragging
      needsPreferredGeometryApplication = false
      log("Split drag began")
    }

    super.mouseDown(with: event)

    if isDividerInteraction {
      finishUserDrag()
    }
  }

  private func reconcileChildren(_ children: [MainSectionOwnedSplitChild]) {
    let nextIDs = Set(children.map(\.id))

    // Remove only panes that actually disappeared. Keeping the existing hosting view for panes
    // that remain visible preserves the editor's NSTextView, first responder and scroll state.
    let removedIDs = hostingViews.keys.filter { !nextIDs.contains($0) }
    for id in removedIDs {
      guard let hostingView = hostingViews.removeValue(forKey: id) else { continue }
      if arrangedSubviews.contains(hostingView) {
        removeArrangedSubview(hostingView)
      }
      hostingView.removeFromSuperview()
    }

    for (index, child) in children.enumerated() {
      let hostingView: NSHostingView<AnyView>
      if let existing = hostingViews[child.id] {
        hostingView = existing
        hostingView.rootView = child.content
      } else {
        let created = NSHostingView(rootView: child.content)
        created.translatesAutoresizingMaskIntoConstraints = true
        hostingViews[child.id] = created
        hostingView = created
      }

      let currentIndex = arrangedSubviews.firstIndex(of: hostingView)
      if currentIndex != index {
        // NSSplitView moves an already-arranged view when inserted at a different index, so the
        // surviving hosting view never needs to be detached from the hierarchy.
        insertArrangedSubview(hostingView, at: min(index, arrangedSubviews.count))
      }
    }
  }

  private func updateHostedContent(_ children: [MainSectionOwnedSplitChild]) {
    for child in children {
      hostingViews[child.id]?.rootView = child.content
    }
  }

  private func applyHoldingPriorities(_ children: [MainSectionOwnedSplitChild]) {
    guard arrangedSubviews.count == children.count else { return }
    for (index, child) in children.enumerated() {
      setHoldingPriority(child.holdingPriority, forSubviewAt: index)
    }
  }

  private func applyPreferredGeometryIfPossible() {
    guard needsPreferredGeometryApplication,
      !isApplyingPreferredGeometry,
      state != .userDragging,
      arrangedSubviews.count == childIDs.count,
      childIDs.count > 1,
      preferredFractions.count == childIDs.count
    else { return }

    let totalLength = isVertical ? bounds.width : bounds.height
    let dividerTotal = dividerThickness * CGFloat(max(0, childIDs.count - 1))
    let availableLength = totalLength - dividerTotal
    guard availableLength > 1 else { return }

    isApplyingPreferredGeometry = true
    defer { isApplyingPreferredGeometry = false }

    let normalized = resolvedFractions(
      preferredFractions,
      availableLength: availableLength
    )
    var cumulative = 0.0
    for dividerIndex in 0..<(normalized.count - 1) {
      cumulative += normalized[dividerIndex]
      let position: CGFloat
      if isVertical {
        position = availableLength * cumulative + dividerThickness * CGFloat(dividerIndex)
      } else {
        // NSSplitView numbers horizontal panes from top to bottom but its Y coordinates originate
        // at the lower edge, so the remaining content below the divider determines its position.
        let dividersBelow = normalized.count - dividerIndex - 2
        position =
          availableLength * (1 - cumulative)
          + dividerThickness * CGFloat(dividersBelow)
      }
      setPosition(position, ofDividerAt: dividerIndex)
    }

    needsPreferredGeometryApplication = false
    state = .ready
    log("Preferred split geometry applied")
  }

  private func finishUserDrag() {
    defer { state = .ready }
    guard arrangedSubviews.count == childIDs.count, childIDs.count > 1 else { return }
    let sizes = arrangedSubviews.map { view in
      Double(isVertical ? view.frame.width : view.frame.height)
    }
    let total = sizes.reduce(0, +)
    guard total > 1 else { return }
    let captured = normalizedFractions(sizes.map { $0 / total }, count: sizes.count)

    preferredFractions = captured
    needsPreferredGeometryApplication = false
    guard !fractionsApproximatelyEqual(captured, modelFractions) else { return }

    lastSubmittedFractions = captured
    log(
      "Split drag committed",
      metadata: ["fractions": captured.map { String(format: "%.4f", $0) }.joined(separator: ",")]
    )
    onPreferredFractionsChanged(captured)
  }

  private func pointIsOnDivider(_ point: NSPoint) -> Bool {
    let views = arrangedSubviews
    guard views.count > 1 else { return false }
    let hitSlop: CGFloat = 4
    let thickness = max(1, dividerThickness)

    for index in 0..<(views.count - 1) {
      let first = views[index].frame
      let second = views[index + 1].frame
      let rect: NSRect
      if isVertical {
        let center = (first.maxX + second.minX) / 2
        rect = NSRect(
          x: center - thickness / 2 - hitSlop,
          y: bounds.minY,
          width: thickness + hitSlop * 2,
          height: bounds.height
        )
      } else {
        let upper = max(first.minY, second.minY)
        let lower = min(first.maxY, second.maxY)
        let center = (upper + lower) / 2
        rect = NSRect(
          x: bounds.minX,
          y: center - thickness / 2 - hitSlop,
          width: bounds.width,
          height: thickness + hitSlop * 2
        )
      }
      if rect.contains(point) { return true }
    }
    return false
  }

  func splitView(
    _ splitView: NSSplitView,
    constrainSplitPosition proposedPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    guard minimumThicknesses.count == arrangedSubviews.count,
      minimumThicknesses.indices.contains(dividerIndex),
      dividerIndex + 1 < minimumThicknesses.count
    else { return proposedPosition }

    let divider = splitView.dividerThickness
    let count = minimumThicknesses.count
    let prefix = minimumThicknesses[0...dividerIndex].reduce(0, +)
    let suffix = minimumThicknesses[(dividerIndex + 1)..<count].reduce(0, +)
    let totalLength = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height

    let minimumPosition: CGFloat
    let maximumPosition: CGFloat
    if splitView.isVertical {
      minimumPosition = prefix + divider * CGFloat(dividerIndex)
      maximumPosition = totalLength - suffix - divider * CGFloat(count - dividerIndex - 1)
    } else {
      minimumPosition = suffix + divider * CGFloat(max(0, count - dividerIndex - 2))
      maximumPosition = totalLength - prefix - divider * CGFloat(dividerIndex + 1)
    }

    guard minimumPosition <= maximumPosition else { return proposedPosition }
    return min(max(proposedPosition, minimumPosition), maximumPosition)
  }

  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
    false
  }

  func splitView(
    _ splitView: NSSplitView,
    additionalEffectiveRectOfDividerAt dividerIndex: Int
  ) -> NSRect {
    guard arrangedSubviews.indices.contains(dividerIndex),
      arrangedSubviews.indices.contains(dividerIndex + 1)
    else { return .zero }
    let first = arrangedSubviews[dividerIndex].frame
    let second = arrangedSubviews[dividerIndex + 1].frame
    if isVertical {
      let center = (first.maxX + second.minX) / 2
      return NSRect(x: center - 4, y: bounds.minY, width: 8, height: bounds.height)
    }
    let center = (first.minY + second.maxY) / 2
    return NSRect(x: bounds.minX, y: center - 4, width: bounds.width, height: 8)
  }

  private func canSatisfyPreferredGeometry(availableLength: CGFloat) -> Bool {
    guard availableLength > 1,
      minimumThicknesses.count == preferredFractions.count,
      preferredFractions.count == childIDs.count
    else { return false }
    let normalized = normalizedFractions(preferredFractions, count: childIDs.count)
    return zip(normalized, minimumThicknesses).allSatisfy { fraction, minimum in
      availableLength * CGFloat(fraction) + 0.5 >= minimum
    }
  }

  private func resolvedFractions(
    _ fractions: [Double],
    availableLength: CGFloat
  ) -> [Double] {
    let normalized = normalizedFractions(fractions, count: childIDs.count)
    guard availableLength > 1,
      minimumThicknesses.count == childIDs.count,
      childIDs.count > 1
    else { return normalized }

    let minimumTotal = minimumThicknesses.reduce(0, +)
    guard minimumTotal < availableLength else { return normalized }

    let desiredSizes = normalized.map { availableLength * CGFloat($0) }
    if zip(desiredSizes, minimumThicknesses).allSatisfy({ $0.0 + 0.5 >= $0.1 }) {
      return normalized
    }

    let remaining = availableLength - minimumTotal
    let desiredExtras = zip(desiredSizes, minimumThicknesses).map { desired, minimum in
      max(0, desired - minimum)
    }
    let desiredExtraTotal = desiredExtras.reduce(0, +)
    let sizes: [CGFloat]
    if desiredExtraTotal > 0.5 {
      sizes = zip(minimumThicknesses, desiredExtras).map { minimum, extra in
        minimum + remaining * (extra / desiredExtraTotal)
      }
    } else {
      let extra = remaining / CGFloat(max(1, childIDs.count))
      sizes = minimumThicknesses.map { $0 + extra }
    }
    return sizes.map { Double($0 / availableLength) }
  }

  private var currentAvailableLength: CGFloat {
    let totalLength = isVertical ? bounds.width : bounds.height
    return max(0, totalLength - dividerThickness * CGFloat(max(0, childIDs.count - 1)))
  }

  private func effectiveFractions() -> [Double] {
    guard arrangedSubviews.count == childIDs.count, !childIDs.isEmpty else { return [] }
    let sizes = arrangedSubviews.map { view in
      Double(isVertical ? view.frame.width : view.frame.height)
    }
    return normalizedFractions(sizes, count: sizes.count)
  }

  private func normalizedFractions(_ values: [Double], count: Int) -> [Double] {
    guard count > 0 else { return [] }
    let sanitized: [Double]
    if values.count == count {
      sanitized = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    } else {
      sanitized = Array(repeating: 1, count: count)
    }
    let total = sanitized.reduce(0, +)
    guard total > 0 else { return Array(repeating: 1 / Double(count), count: count) }
    return sanitized.map { $0 / total }
  }

  private func fractionsApproximatelyEqual(_ lhs: [Double], _ rhs: [Double]) -> Bool {
    lhs.count == rhs.count
      && zip(lhs, rhs).allSatisfy { abs($0.0 - $0.1) <= 0.000_5 }
  }

  private func log(_ message: String, metadata: [String: String] = [:]) {
    var nextMetadata = metadata
    nextMetadata["split_id"] = splitID.uuidString
    nextMetadata["state"] = state.rawValue
    CalciteLogStore.shared.log(
      .debug,
      category: "Layout",
      message: message,
      metadata: nextMetadata
    )
  }
}

@MainActor
private struct MainSectionKeyboardFocusInstaller: NSViewRepresentable {
  let kind: MainSectionKind
  let isActive: Bool
  let focusToken: String

  func makeNSView(context: Context) -> MainSectionKeyboardFocusLocatorView {
    MainSectionKeyboardFocusLocatorView(
      kind: kind,
      isActive: false,
      focusToken: ""
    )
  }

  func updateNSView(
    _ nsView: MainSectionKeyboardFocusLocatorView,
    context: Context
  ) {
    let shouldFocus =
      isActive && (!nsView.isActive || nsView.kind != kind || nsView.focusToken != focusToken)
    nsView.kind = kind
    nsView.isActive = isActive
    nsView.focusToken = focusToken
    if shouldFocus { nsView.scheduleFocusIfNeeded() }
  }
}

@MainActor
private final class MainSectionKeyboardFocusLocatorView: NSView {
  var kind: MainSectionKind
  var isActive: Bool
  var focusToken: String
  private var focusGeneration = UUID()
  private var focusTask: Task<Void, Never>?

  init(kind: MainSectionKind, isActive: Bool, focusToken: String) {
    self.kind = kind
    self.isActive = isActive
    self.focusToken = focusToken
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    focusTask?.cancel()
  }

  override var acceptsFirstResponder: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func scheduleFocusIfNeeded() {
    guard isActive else { return }
    let generation = UUID()
    focusGeneration = generation
    focusTask?.cancel()
    focusTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled,
        self.focusGeneration == generation, self.isActive
      else { return }
      self.focusNearestInput()
      self.focusTask = nil
    }
  }

  private func focusNearestInput() {
    guard let window, let contentView = window.contentView else { return }
    let matchesInput: (NSView) -> Bool
    switch kind {
    case .workspace, .editor:
      // An editor section may host Calcite's native editor or a real Vim/Neovim
      // terminal. Focus whichever input belongs to the newly active section.
      matchesInput = { $0 is CodeEditorTextView || $0 is TerminalInputTextView }
    case .panel, .terminal:
      matchesInput = { $0 is TerminalInputTextView }
    case .sidebar, .symbols, .settings, .themeBuilder, .problems, .buildOutput, .debug, .empty:
      return
    }

    let locatorCenter = convert(
      NSPoint(x: bounds.midX, y: bounds.midY),
      to: contentView
    )
    let candidates = descendantViews(in: contentView).filter(matchesInput)
    guard
      let target = candidates.min(by: { lhs, rhs in
        distanceSquared(from: lhs, to: locatorCenter, in: contentView)
          < distanceSquared(from: rhs, to: locatorCenter, in: contentView)
      })
    else { return }
    if window.firstResponder !== target {
      window.makeFirstResponder(target)
    }
  }

  private func descendantViews(in root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendantViews(in: $0) }
  }

  private func distanceSquared(
    from view: NSView,
    to point: NSPoint,
    in coordinateView: NSView
  ) -> CGFloat {
    let frame = view.convert(view.bounds, to: coordinateView)
    let dx = frame.midX - point.x
    let dy = frame.midY - point.y
    return dx * dx + dy * dy
  }
}

@MainActor
private struct MainSectionLeafView: View {
  let node: MainSectionLayoutNode
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject var layout: MainSectionalLayoutController
  let parentSplitAxis: MainSectionSplitAxis?
  @AppStorage(EditorInterfacePreferences.showsEditorTabBarKey)
  private var showsEditorTabBar = true

  @State private var isHovering = false

  private var sectionID: UUID { node.id }
  private var selectedTab: MainSectionTab? { node.selectedVisibleTab }
  private var selectedKind: MainSectionKind { selectedTab?.kind ?? .empty }
  private var primaryEditorTabID: UUID? {
    node.visibleTabs.first(where: { isEditorHost($0.kind) })?.id
  }
  private var isEditorSection: Bool {
    node.visibleTabs.contains { isEditorHost($0.kind) }
  }

  var body: some View {
    VStack(spacing: 0) {
      if node.isSectionVisible {
        if node.showsTabBar && (!isEditorSection || showsEditorTabBar) {
          integratedTabBar
          Divider()
        } else if !isEditorSection || showsEditorTabBar || layout.isCustomizing {
          compactSectionHeader
          Divider()
        }

        if let selectedTab {
          MainSectionContentView(
            sectionID: sectionID,
            tabID: selectedTab.id,
            kind: selectedTab.kind,
            backend: backend,
            windowSession: windowSession,
            layout: layout
          )
          .id(selectedTab.id)
          .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
      } else {
        collapsedSectionHeader
      }
    }
    .frame(
      minWidth: minimumWidth,
      maxWidth: maximumWidth,
      minHeight: minimumHeight,
      maxHeight: maximumHeight
    )
    .background {
      MainSectionKeyboardFocusInstaller(
        kind: selectedKind,
        isActive: layout.activeSectionID == sectionID,
        focusToken:
          "\(selectedTab?.id.uuidString ?? "empty")|\(backend.activeDocumentID?.uuidString ?? "none")"
      )
    }
    .background(sectionBackground)
    .overlay {
      Rectangle()
        .stroke(
          borderColor,
          lineWidth: sectionBorderWidth
        )
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .contextMenu { sectionMenu }
    .onHover { isHovering = $0 }
    .simultaneousGesture(
      TapGesture().onEnded {
        windowSession.markActive()
        windowSession.activateSection(sectionID)
      }
    )
  }

  private var integratedTabBar: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: 0) {
          ForEach(node.visibleTabs) { tab in
            if isEditorHost(tab.kind),
              tab.id == primaryEditorTabID,
              !backend.documents.isEmpty
            {
              ForEach(backend.documents) { document in
                documentTab(document, editorTab: tab)
                Divider()
              }
            } else {
              sectionTab(tab)
              Divider()
            }
          }
        }
      }
      .scrollIndicators(.hidden)
      .frame(maxWidth: .infinity)

      sectionVisibilityButton
      addTabMenu

      if layout.isCustomizing {
        Menu {
          sectionMenu
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .help("Section options")
        .padding(.trailing, 3)
      }
    }
    .frame(height: 30)
    .background(.bar)
    .animation(.snappy(duration: 0.22, extraBounce: 0.08), value: tabAnimationIDs)
    .animation(.easeInOut(duration: 0.16), value: selectedTab?.id)
  }

  private var compactSectionHeader: some View {
    HStack(spacing: 6) {
      if layout.isCustomizing {
        Label(selectedKind.title, systemImage: selectedKind.systemImage)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      sectionVisibilityButton
      Menu {
        sectionMenu
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 24, height: 22)
      }
      .menuStyle(.borderlessButton)
      .help("Section options")
    }
    .padding(.leading, 8)
    .padding(.trailing, 3)
    .frame(height: 24)
    .background(.bar)
  }

  private var collapsedSectionHeader: some View {
    Group {
      if parentSplitAxis == .horizontal {
        VStack(spacing: 0) {
          sectionVisibilityButton
          Spacer(minLength: 0)
        }
      } else {
        HStack(spacing: 6) {
          if layout.isCustomizing {
            Label(selectedKind.title, systemImage: selectedKind.systemImage)
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          sectionVisibilityButton
        }
      }
    }
    .padding(parentSplitAxis == .horizontal ? 2 : 0)
    .padding(.leading, parentSplitAxis == .horizontal ? 0 : 8)
    .padding(.trailing, parentSplitAxis == .horizontal ? 0 : 3)
    .frame(
      maxWidth: parentSplitAxis == .horizontal ? 28 : .infinity,
      maxHeight: parentSplitAxis == .horizontal ? .infinity : 24
    )
    .background(.bar)
  }

  private var minimumWidth: CGFloat {
    guard !node.isSectionVisible else { return CGFloat(selectedKind.minimumWidth) }
    return parentSplitAxis == .horizontal ? 28 : 80
  }

  private var maximumWidth: CGFloat {
    !node.isSectionVisible && parentSplitAxis == .horizontal ? 28 : .infinity
  }

  private var minimumHeight: CGFloat {
    guard !node.isSectionVisible else { return CGFloat(selectedKind.minimumHeight) }
    return parentSplitAxis == .horizontal ? 80 : 24
  }

  private var maximumHeight: CGFloat {
    !node.isSectionVisible && parentSplitAxis != .horizontal ? 24 : .infinity
  }

  private var sectionVisibilityButton: some View {
    let isVisible = layout.isSectionVisible(sectionID)
    return Button {
      layout.toggleSectionFastPanel(for: sectionID)
    } label: {
      Image(systemName: isVisible ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .help(isVisible ? "Collapse section" : "Restore section")
    .accessibilityLabel(
      isVisible ? "Collapse section" : "Restore section"
    )
  }

  private var tabAnimationIDs: [UUID] {
    node.visibleTabs.flatMap { tab in
      if isEditorHost(tab.kind), tab.id == primaryEditorTabID {
        return [tab.id] + backend.documents.map(\.id)
      }
      return [tab.id]
    }
  }

  private var addTabMenu: some View {
    Menu {
      addTabItems
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 26, height: 26)
    }
    .menuStyle(.borderlessButton)
    .help("Add tab")
  }

  @ViewBuilder
  private var addTabItems: some View {
    ForEach(MainSectionKind.tabCases) { kind in
      Button {
        layout.addTab(to: sectionID, kind: kind)
      } label: {
        Label(kind.title, systemImage: kind.systemImage)
      }
    }
  }

  private func documentTab(_ document: EditorTab, editorTab: MainSectionTab) -> some View {
    let isSelected =
      selectedTab?.id == editorTab.id
      && selectedDocumentID(for: editorTab) == document.id

    return HStack(spacing: 0) {
      Button {
        select(document, in: editorTab)
      } label: {
        EditorTabLabel(tab: document, isSelected: isSelected)
      }
      .buttonStyle(.plain)

      Button {
        windowSession.requestCloseDocument(document)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .padding(6)
      }
      .buttonStyle(.plain)
      .help("Close \(document.title)")
    }
    .background {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button {
        select(document, in: editorTab)
        Task { _ = await document.save() }
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      .disabled(!document.isDirty)

      Divider()

      Button {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.url.path, forType: .string)
      } label: {
        Label("Copy Path", systemImage: "doc.on.doc")
      }

      Divider()

      Button("Close Tab", systemImage: "xmark", role: .destructive) {
        windowSession.requestCloseDocument(document)
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
  }

  private func sectionTab(_ tab: MainSectionTab) -> some View {
    HStack(spacing: 0) {
      Button {
        selectSectionTab(tab)
      } label: {
        Label(tab.kind.title, systemImage: tab.kind.systemImage)
          .font(.system(size: 11))
          .lineLimit(1)
          .padding(.leading, 9)
          .padding(.vertical, 6)
      }
      .buttonStyle(.plain)

      Button {
        layout.removeTab(sectionID: sectionID, tabID: tab.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .padding(6)
      }
      .buttonStyle(.plain)
      .help("Close \(tab.kind.title) tab")
    }
    .background {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(selectedTab?.id == tab.id ? Color.accentColor.opacity(0.14) : .clear)
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }
    .contentShape(Rectangle())
    .contextMenu {
      Menu("Replace Tab", systemImage: "rectangle.on.rectangle") {
        ForEach(MainSectionKind.tabCases) { replacement in
          Button {
            layout.replaceTab(sectionID: sectionID, tabID: tab.id, with: replacement)
          } label: {
            Label(replacement.title, systemImage: replacement.systemImage)
          }
          .disabled(replacement == tab.kind)
        }
      }
      Divider()
      Button("Close Tab", systemImage: "xmark", role: .destructive) {
        layout.removeTab(sectionID: sectionID, tabID: tab.id)
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
  }

  private func isEditorHost(_ kind: MainSectionKind) -> Bool {
    kind == .editor || kind == .workspace
  }

  private func selectedDocumentID(for editorTab: MainSectionTab) -> UUID? {
    windowSession.documentIDAssigned(toSection: editorTab.id)
      ?? backend.activeDocumentID
  }

  private func select(_ document: EditorTab, in editorTab: MainSectionTab) {
    layout.selectTab(sectionID: sectionID, tabID: editorTab.id)
    _ = windowSession.selectDocument(document.id, inSection: editorTab.id)
  }

  private func selectSectionTab(_ tab: MainSectionTab) {
    layout.selectTab(sectionID: sectionID, tabID: tab.id)
    windowSession.activateSection(sectionID)
  }

  @ViewBuilder
  private var sectionMenu: some View {
    Menu("Select Tab", systemImage: "rectangle.stack") {
      selectionMenuItems
    }

    Menu("Add Tab", systemImage: "plus") {
      addTabItems
    }

    Button(
      node.showsTabBar ? "Hide Section Tabs" : "Show Section Tabs",
      systemImage: node.showsTabBar ? "rectangle.topthird.inset.filled" : "rectangle.topthird.inset"
    ) {
      layout.setTabBarVisible(sectionID: sectionID, isVisible: !node.showsTabBar)
    }

    Button(
      layout.isFastPanel(sectionID) ? "Remove from Fast Panels" : "Use as Fast Panel",
      systemImage: layout.isFastPanel(sectionID) ? "bolt.slash" : "bolt"
    ) {
      layout.toggleFastPanelMembership(for: sectionID)
    }

    Divider()

    Menu("Add Section Right", systemImage: "rectangle.righthalf.inset.filled") {
      sectionInsertionMenu(axis: .horizontal, placement: .after)
    }
    Menu("Add Section Left", systemImage: "rectangle.lefthalf.inset.filled") {
      sectionInsertionMenu(axis: .horizontal, placement: .before)
    }
    Menu("Add Section Below", systemImage: "rectangle.bottomhalf.inset.filled") {
      sectionInsertionMenu(axis: .vertical, placement: .after)
    }
    Menu("Add Section Above", systemImage: "rectangle.tophalf.inset.filled") {
      sectionInsertionMenu(axis: .vertical, placement: .before)
    }

    Divider()

    if let swapSource = layout.swapSourceSectionID {
      if swapSource == sectionID {
        Button("Cancel Swap", systemImage: "xmark") {
          layout.cancelSectionSwap()
        }
      } else {
        Button("Swap with Selected Section", systemImage: "arrow.left.arrow.right") {
          layout.swapWithSelectedSection(sectionID)
        }
      }
    } else {
      Button("Select for Swap", systemImage: "arrow.left.arrow.right") {
        layout.selectSectionForSwap(sectionID)
      }
    }

    Divider()

    Button("Remove Section", systemImage: "trash", role: .destructive) {
      layout.removeSection(id: sectionID)
    }
    .disabled(layout.leafCount <= 1)
  }

  @ViewBuilder
  private var selectionMenuItems: some View {
    ForEach(node.visibleTabs) { tab in
      if isEditorHost(tab.kind),
        tab.id == primaryEditorTabID,
        !backend.documents.isEmpty
      {
        Menu("Editor", systemImage: "doc.text") {
          ForEach(backend.documents) { document in
            Button {
              select(document, in: tab)
            } label: {
              Label(document.title, systemImage: "doc.text")
            }
          }
        }
      } else {
        Button {
          selectSectionTab(tab)
        } label: {
          Label(tab.kind.title, systemImage: tab.kind.systemImage)
        }
      }
    }
  }

  @ViewBuilder
  private func sectionInsertionMenu(
    axis: MainSectionSplitAxis,
    placement: MainSectionPlacement
  ) -> some View {
    ForEach(MainSectionKind.tabCases) { insertedKind in
      Button {
        layout.splitSection(
          id: sectionID,
          axis: axis,
          newKind: insertedKind,
          placement: placement
        )
      } label: {
        Label(insertedKind.title, systemImage: insertedKind.systemImage)
      }
    }
  }

  private var sectionBackground: Color {
    switch selectedKind {
    case .sidebar, .symbols:
      backend.controller.profile.workbench.sidebarBackground.color
    case .panel, .terminal, .problems, .buildOutput, .debug:
      backend.controller.profile.workbench.panelBackground.color
    case .workspace, .editor, .settings, .themeBuilder, .empty:
      backend.controller.profile.workbench.windowBackground.color
    }
  }

  private var sectionBorderWidth: CGFloat {
    if layout.swapSourceSectionID == sectionID || layout.isCustomizing { return 1.5 }
    return layout.activeSectionID == sectionID ? 1 : 0
  }

  private var borderColor: Color {
    if layout.swapSourceSectionID == sectionID { return .accentColor }
    if layout.isCustomizing && isHovering { return .accentColor.opacity(0.8) }
    if layout.activeSectionID == sectionID { return .accentColor.opacity(0.45) }
    return backend.controller.profile.workbench.border.color.opacity(0.65)
  }
}

@MainActor
private struct MainSectionContentView: View {
  let sectionID: UUID
  let tabID: UUID
  let kind: MainSectionKind
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession
  @ObservedObject var layout: MainSectionalLayoutController

  @ViewBuilder
  var body: some View {
    switch kind {
    case .workspace, .editor:
      MainSectionCalciteEditorSurface(
        tabID: tabID,
        backend: backend,
        windowSession: windowSession
      )

    case .panel, .terminal:
      CalciteTerminalView(backend: backend, windowSession: windowSession)

    case .sidebar:
      CalciteWorkspaceSidebar(
        backend: backend,
        windowSession: windowSession
      )

    case .symbols:
      CalciteSymbolsView(
        backend: backend,
        windowSession: windowSession
      )

    case .settings:
      CalciteSettingsView(
        backend: backend,
        windowSession: windowSession
      )

    case .themeBuilder:
      CalciteThemeBuilderView(
        backend: backend,
        windowSession: windowSession
      )

    case .problems:
      CalciteProblemsView(backend: backend, windowSession: windowSession)

    case .buildOutput:
      CalciteBuildOutputView(backend: backend)

    case .debug:
      CalciteDebugPanelView(backend: backend)

    case .empty:
      MainSectionEmptyView(
        sectionID: sectionID,
        tabID: tabID,
        layout: layout
      )
    }
  }
}

@MainActor
private struct MainSectionCalciteEditorSurface: View {
  let tabID: UUID
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  @State private var editorSessionID: UUID?

  init(
    tabID: UUID,
    backend: CalciteBackend,
    windowSession: CalciteBackendWindowSession
  ) {
    self.tabID = tabID
    self.backend = backend
    self.windowSession = windowSession
    // Assigning an editor session mutates the shared window model.  Keep view
    // construction read-only; the assignment is made after this surface appears.
    _editorSessionID = State(initialValue: nil)
  }

  private var editorSessionIDs: [UUID] {
    windowSession.editorSessions.map(\.id)
  }

  private var assignedEditorSessionID: UUID? {
    windowSession.editorSessionAssigned(toSection: tabID)?.id
  }

  @ViewBuilder
  var body: some View {
    if editorSessionID != nil {
      editorDetail
        .onAppear(perform: assignEditorSessionIfNeeded)
        .onChange(of: editorSessionIDs) { _, _ in
          assignEditorSessionIfNeeded()
        }
        .onChange(of: assignedEditorSessionID) { _, assignedID in
          if editorSessionID != assignedID { editorSessionID = assignedID }
        }
    } else {
      CalciteEditorEmptyState(backend: backend)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: assignEditorSessionIfNeeded)
        .onChange(of: editorSessionIDs) { _, _ in
          assignEditorSessionIfNeeded()
        }
        .onChange(of: assignedEditorSessionID) { _, assignedID in
          if editorSessionID != assignedID { editorSessionID = assignedID }
        }
    }
  }

  private var editorDetail: some View {
    CalciteEditorDetailView(
      backend: backend,
      windowSession: windowSession,
      followsActiveEditorSession: false,
      preferredEditorSessionID: editorSessionID,
      editorSessionDidChange: handleEditorSessionChange
    )
  }

  private func handleEditorSessionChange(_ editorID: UUID?) {
    editorSessionID = editorID
    windowSession.updateEditorSessionAssignment(
      forSection: tabID,
      editorSessionID: editorID
    )
  }

  private func assignEditorSessionIfNeeded() {
    if let editorSessionID, editorSessionIDs.contains(editorSessionID) {
      windowSession.updateEditorSessionAssignment(
        forSection: tabID,
        editorSessionID: editorSessionID
      )
      return
    }
    editorSessionID = windowSession.assignEditorSession(toSection: tabID)
  }
}

@MainActor
private struct MainSectionEmptyView: View {
  let sectionID: UUID
  let tabID: UUID
  @ObservedObject var layout: MainSectionalLayoutController

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.dashed")
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(.secondary)
      Text("Empty Section").font(.headline)
      Menu("Choose Content") {
        ForEach(MainSectionKind.tabCases) { kind in
          Button {
            layout.replaceTab(sectionID: sectionID, tabID: tabID, with: kind)
          } label: {
            Label(kind.title, systemImage: kind.systemImage)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
