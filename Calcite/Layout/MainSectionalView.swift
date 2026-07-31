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
    if visibleChildren.count == 1, let child = visibleChildren.first {
      MainSectionLayoutNodeView(
        node: child,
        backend: backend,
        windowSession: windowSession,
        layout: layout,
        parentSplitAxis: node.splitAxis
      )
    } else {
      switch node.splitAxis ?? .horizontal {
      case .horizontal:
        HSplitView { splitChildren }
          .background(splitAutosaveInstaller.allowsHitTesting(false))
      case .vertical:
        VSplitView { splitChildren }
          .background(splitAutosaveInstaller.allowsHitTesting(false))
      }
    }
  }

  @ViewBuilder
  private var splitChildren: some View {
    ForEach(visibleChildren) { child in
      MainSectionLayoutNodeView(
        node: child,
        backend: backend,
        windowSession: windowSession,
        layout: layout,
        parentSplitAxis: node.splitAxis
      )
    }
  }

  private var splitAutosaveInstaller: some View {
    let childIDs = visibleChildren.map(\.id)
    let defaultSecondaryFraction = windowSession.layoutProfile.defaultSecondaryFraction(
      for: node.splitAxis,
      childCount: visibleChildren.count
    )
    return MainSectionSplitGeometryInstaller(
      splitID: node.id,
      childIDs: childIDs,
      isGeometryEnabled: visibleChildren.allSatisfy(\.hasVisibleContent),
      fractions: layout.splitFractions(
        for: node.id,
        visibleChildIDs: childIDs,
        defaultSecondaryFraction: defaultSecondaryFraction.map { Double($0) }
      ),
      onFractionsChanged: { fractions in
        layout.updateSplitFractions(
          splitID: node.id,
          visibleChildIDs: childIDs,
          fractions: fractions
        )
      }
    )
  }
}

/// Bridges SwiftUI's `HSplitView` / `VSplitView` to the controller-owned geometry model. AppKit
/// remains responsible for interactive divider dragging, while persisted fractions are keyed by
/// stable split and child IDs instead of by temporary SwiftUI view identity.
@MainActor
private struct MainSectionSplitGeometryInstaller: NSViewRepresentable {
  let splitID: UUID
  let childIDs: [UUID]
  let isGeometryEnabled: Bool
  let fractions: [Double]
  let onFractionsChanged: ([Double]) -> Void

  func makeNSView(context: Context) -> MainSectionSplitGeometryLocatorView {
    MainSectionSplitGeometryLocatorView(
      splitID: splitID,
      childIDs: childIDs,
      isGeometryEnabled: isGeometryEnabled,
      fractions: fractions,
      onFractionsChanged: onFractionsChanged
    )
  }

  func updateNSView(
    _ nsView: MainSectionSplitGeometryLocatorView,
    context: Context
  ) {
    nsView.splitID = splitID
    nsView.childIDs = childIDs
    nsView.isGeometryEnabled = isGeometryEnabled
    nsView.fractions = fractions
    nsView.onFractionsChanged = onFractionsChanged
    nsView.scheduleInstallation()
  }
}

@MainActor
private final class MainSectionSplitGeometryLocatorView: NSView {
  var splitID: UUID
  var childIDs: [UUID]
  var isGeometryEnabled: Bool {
    didSet {
      if oldValue != isGeometryEnabled { lastAppliedSignature = "" }
    }
  }
  var fractions: [Double]
  var onFractionsChanged: ([Double]) -> Void

  private weak var installedSplitView: NSSplitView?
  private var mouseEventMonitor: Any?
  private var installationWorkItem: DispatchWorkItem?
  private var captureWorkItem: DispatchWorkItem?
  private var geometryReleaseWorkItem: DispatchWorkItem?
  private var geometryApplyGeneration: UInt64 = 0
  private var isApplyingGeometry = false
  private var isUserResizing = false
  private var lastAppliedSignature = ""

  init(
    splitID: UUID,
    childIDs: [UUID],
    isGeometryEnabled: Bool,
    fractions: [Double],
    onFractionsChanged: @escaping ([Double]) -> Void
  ) {
    self.splitID = splitID
    self.childIDs = childIDs
    self.isGeometryEnabled = isGeometryEnabled
    self.fractions = fractions
    self.onFractionsChanged = onFractionsChanged
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      tearDownObservation()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  private func tearDownObservation() {
    installationWorkItem?.cancel()
    installationWorkItem = nil
    captureWorkItem?.cancel()
    captureWorkItem = nil
    geometryReleaseWorkItem?.cancel()
    geometryReleaseWorkItem = nil
    if let mouseEventMonitor {
      NSEvent.removeMonitor(mouseEventMonitor)
      self.mouseEventMonitor = nil
    }
    installedSplitView = nil
    isUserResizing = false
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleInstallation()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleInstallation()
  }

  override var acceptsFirstResponder: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // This view only discovers its containing NSSplitView. It must never become
    // an input surface, otherwise it can swallow clicks intended for NSTextView.
    nil
  }

  override func layout() {
    super.layout()
    scheduleInstallation()
  }

  func scheduleInstallation() {
    // SwiftUI can rebuild a split and report several transient frames in the same run-loop turn.
    // Apply once after the hierarchy has settled instead of pushing persisted geometry into each
    // intermediate frame.
    guard installationWorkItem == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.installationWorkItem = nil
        self.installAndApplyGeometry()
      }
    }
    installationWorkItem = workItem
    DispatchQueue.main.async(execute: workItem)
  }

  private func installAndApplyGeometry() {
    guard let splitView = containingSplitView() else { return }
    if installedSplitView !== splitView { installObserver(for: splitView) }
    applyGeometry(to: splitView)
  }

  private func containingSplitView() -> NSSplitView? {
    var candidate = superview
    while let view = candidate {
      if let splitView = view as? NSSplitView { return splitView }
      candidate = view.superview
    }
    return nil
  }

  private func installObserver(for splitView: NSSplitView) {
    if let mouseEventMonitor { NSEvent.removeMonitor(mouseEventMonitor) }
    installedSplitView = splitView
    isUserResizing = false
    lastAppliedSignature = ""
    mouseEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self, weak splitView] event in
      guard let self, let splitView, event.window === splitView.window else { return event }
      switch event.type {
      case .leftMouseDown:
        let point = splitView.convert(event.locationInWindow, from: nil)
        guard self.isPointOnDivider(point, in: splitView) else { return event }
        self.captureWorkItem?.cancel()
        self.captureWorkItem = nil
        self.isUserResizing = true
      case .leftMouseUp:
        guard self.isUserResizing else { return event }
        self.finishUserResize(in: splitView)
      case .leftMouseDragged:
        break
      default:
        break
      }
      return event
    }
  }

  private func finishUserResize(in splitView: NSSplitView) {
    captureWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self, weak splitView] in
      MainActor.assumeIsolated {
        guard let self else { return }
        defer {
          self.isUserResizing = false
          self.captureWorkItem = nil
          self.scheduleInstallation()
        }
        guard let splitView, !self.isApplyingGeometry,
          self.installedSplitView === splitView
        else { return }
        self.captureGeometry(from: splitView)
      }
    }
    captureWorkItem = workItem
    // Let NSSplitView finish the mouse-up layout before reading its final frames.
    DispatchQueue.main.async(execute: workItem)
  }

  private func isPointOnDivider(_ point: NSPoint, in splitView: NSSplitView) -> Bool {
    let subviews = splitView.arrangedSubviews
    guard subviews.count > 1 else { return false }
    let hitSlop: CGFloat = 4
    let thickness = max(1, splitView.dividerThickness)

    for index in 0..<(subviews.count - 1) {
      let first = subviews[index].frame
      let second = subviews[index + 1].frame
      let dividerRect: NSRect
      if splitView.isVertical {
        let dividerCenter: CGFloat
        if first.maxX <= second.minX {
          dividerCenter = (first.maxX + second.minX) / 2
        } else if second.maxX <= first.minX {
          dividerCenter = (second.maxX + first.minX) / 2
        } else {
          dividerCenter = (first.midX + second.midX) / 2
        }
        dividerRect = NSRect(
          x: dividerCenter - thickness / 2 - hitSlop,
          y: splitView.bounds.minY,
          width: thickness + hitSlop * 2,
          height: splitView.bounds.height
        )
      } else {
        let dividerCenter: CGFloat
        if first.maxY <= second.minY {
          dividerCenter = (first.maxY + second.minY) / 2
        } else if second.maxY <= first.minY {
          dividerCenter = (second.maxY + first.minY) / 2
        } else {
          dividerCenter = (first.midY + second.midY) / 2
        }
        dividerRect = NSRect(
          x: splitView.bounds.minX,
          y: dividerCenter - thickness / 2 - hitSlop,
          width: splitView.bounds.width,
          height: thickness + hitSlop * 2
        )
      }
      if dividerRect.contains(point) { return true }
    }
    return false
  }

  private func applyGeometry(to splitView: NSSplitView) {
    guard isGeometryEnabled, !isApplyingGeometry, !isUserResizing,
      childIDs.count > 1,
      splitView.arrangedSubviews.count == childIDs.count,
      fractions.count == childIDs.count
    else { return }

    let boundsLength = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    let dividerCount = normalizedDividerCount(childCount: childIDs.count)
    let dividerTotal = splitView.dividerThickness * CGFloat(dividerCount)
    let availableLength = boundsLength - dividerTotal
    guard availableLength > 1 else { return }
    let normalized = normalizedFractions(fractions)
    let signature =
      "\(splitID.uuidString)|\(childIDs.map(\.uuidString).joined(separator: ","))|"
      + normalized.map { String(format: "%.6f", $0) }.joined(separator: ",")
      + "|\(Int(boundsLength.rounded()))"
    guard signature != lastAppliedSignature else { return }

    geometryApplyGeneration &+= 1
    let applyGeneration = geometryApplyGeneration
    geometryReleaseWorkItem?.cancel()
    isApplyingGeometry = true
    var cumulative = 0.0
    for dividerIndex in 0..<(normalized.count - 1) {
      cumulative += normalized[dividerIndex]
      let position: CGFloat
      if splitView.isVertical {
        // Left-to-right content: preceding content plus the preceding dividers.
        position =
          availableLength * cumulative
          + splitView.dividerThickness * CGFloat(dividerIndex)
      } else {
        // Top-to-bottom content: AppKit measures from the lower edge, so count the content and
        // dividers that remain below this divider.
        let dividersBelow = normalized.count - dividerIndex - 2
        position =
          availableLength * (1 - cumulative)
          + splitView.dividerThickness * CGFloat(dividersBelow)
      }
      splitView.setPosition(position, ofDividerAt: dividerIndex)
    }
    lastAppliedSignature = signature
    let releaseWorkItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.geometryApplyGeneration == applyGeneration else { return }
        self.isApplyingGeometry = false
        self.geometryReleaseWorkItem = nil
      }
    }
    geometryReleaseWorkItem = releaseWorkItem
    DispatchQueue.main.async(execute: releaseWorkItem)
  }

  private func captureGeometry(from splitView: NSSplitView) {
    guard isGeometryEnabled,
      !isApplyingGeometry,
      splitView.arrangedSubviews.count == childIDs.count,
      childIDs.count > 1
    else { return }
    let sizes = splitView.arrangedSubviews.map { view in
      Double(splitView.isVertical ? view.frame.width : view.frame.height)
    }
    let total = sizes.reduce(0, +)
    guard total > 1 else { return }
    let captured = sizes.map { $0 / total }
    let normalizedCurrent = normalizedFractions(fractions)
    guard
      zip(captured, normalizedCurrent).contains(
        where: { pair in abs(pair.0 - pair.1) > 0.001 }
      )
    else {
      return
    }
    fractions = captured
    lastAppliedSignature = ""
    onFractionsChanged(captured)
  }

  private func normalizedDividerCount(childCount: Int) -> Int {
    max(0, childCount - 1)
  }

  private func normalizedFractions(_ values: [Double]) -> [Double] {
    let sanitized = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
    let total = sanitized.reduce(0, +)
    guard total > 0 else { return Array(repeating: 1 / Double(values.count), count: values.count) }
    return sanitized.map { $0 / total }
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
