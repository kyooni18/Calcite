import AppKit
import Foundation
import SwiftUI

struct EditorFindReplaceBar: View {
  let text: String
  let textRevision: UInt64
  let selection: NSRange
  @Binding var query: String
  @Binding var replacement: String
  @Binding var showsReplace: Bool
  let close: () -> Void
  let select: (NSRange) -> Void
  let replaceCurrent: (NSRange) -> Void
  let replaceAll: () -> Void

  @FocusState private var queryIsFocused: Bool
  @State private var matches: [NSRange] = []
  @State private var searchTask: Task<Void, Never>?
  @State private var searchGeneration: UInt64 = 0

  private var currentIndex: Int? {
    matches.firstIndex { NSLocationInRange(selection.location, $0) }
      ?? matches.firstIndex { $0.location >= selection.location }
      ?? matches.indices.first
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(spacing: 6) {
        TextField("Find", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
          .focused($queryIsFocused)
          .onSubmit { move(forward: true) }
        Text(matchPositionText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(minWidth: 64, alignment: .leading)
        Button(action: { move(forward: false) }) {
          Image(systemName: "chevron.up")
        }
        .help("Previous match")
        .disabled(matches.isEmpty)
        Button(action: { move(forward: true) }) {
          Image(systemName: "chevron.down")
        }
        .help("Next match")
        .disabled(matches.isEmpty)
        Button(action: { showsReplace.toggle() }) {
          Image(systemName: "arrow.left.arrow.right")
        }
        .help("Show replace")
        Button(action: close) {
          Image(systemName: "xmark")
        }
        .help("Close Find")
      }
      if showsReplace {
        HStack(spacing: 6) {
          TextField("Replace", text: $replacement)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
          Button("Replace") {
            if let index = currentIndex { replaceCurrent(matches[index]) }
          }
          .disabled(matches.isEmpty)
          Button("Replace All", action: replaceAll)
            .disabled(matches.isEmpty)
        }
      }
    }
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(FindReplaceEscapeHandler(onEscape: close))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    .onAppear {
      queryIsFocused = true
      scheduleSearch(selectInitialResult: false)
    }
    .onChange(of: query) { _, _ in scheduleSearch(selectInitialResult: true) }
    .onChange(of: textRevision) { _, _ in scheduleSearch(selectInitialResult: false) }
    .onDisappear {
      searchGeneration &+= 1
      searchTask?.cancel()
    }
    .onKeyPress(.downArrow) {
      move(forward: true)
      return .handled
    }
    .onKeyPress(.upArrow) {
      move(forward: false)
      return .handled
    }
    .onKeyPress(.escape) {
      close()
      return .handled
    }
  }

  private var matchPositionText: String {
    guard !matches.isEmpty else { return "No results" }
    return "\((currentIndex ?? 0) + 1)/\(matches.count)"
  }

  private func scheduleSearch(selectInitialResult: Bool) {
    searchGeneration &+= 1
    let generation = searchGeneration
    let source = text
    let needle = query
    searchTask?.cancel()

    guard !needle.isEmpty else {
      matches = []
      return
    }

    searchTask = Task {
      let worker = Task.detached(priority: .userInitiated) {
        Self.findRanges(of: needle, in: source)
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled, generation == searchGeneration else { return }
      matches = result
      if selectInitialResult {
        selectInitialMatch(in: result)
      }
    }
  }

  private func selectInitialMatch(in values: [NSRange]) {
    guard let match = values.first(where: { $0.location >= selection.location }) ?? values.first
    else { return }
    select(match)
  }

  private func move(forward: Bool) {
    guard !matches.isEmpty else { return }
    let current = currentIndex ?? 0
    let index =
      forward
      ? (current + 1) % matches.count
      : (current - 1 + matches.count) % matches.count
    select(matches[index])
  }

  nonisolated private static func findRanges(of query: String, in text: String) -> [NSRange] {
    let source = text as NSString
    var results: [NSRange] = []
    var searchRange = NSRange(location: 0, length: source.length)
    while searchRange.length > 0 {
      if Task.isCancelled { return [] }
      let range = source.range(of: query, options: [], range: searchRange)
      guard range.location != NSNotFound else { break }
      results.append(range)
      let next = NSMaxRange(range)
      searchRange = NSRange(location: next, length: source.length - next)
    }
    return results
  }
}

/// `TextField` receives Escape through AppKit's responder chain, bypassing SwiftUI's
/// `onKeyPress`. Listen at the owning window so Escape closes the panel even while either
/// native text field has focus.
private struct FindReplaceEscapeHandler: NSViewRepresentable {
  let onEscape: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

  func makeNSView(context: Context) -> EscapeHandlerView {
    EscapeHandlerView(coordinator: context.coordinator)
  }

  func updateNSView(_ view: EscapeHandlerView, context: Context) {
    context.coordinator.onEscape = onEscape
    context.coordinator.attach(to: view.window)
  }

  final class Coordinator {
    var onEscape: () -> Void
    private weak var window: NSWindow?
    private var monitor: Any?

    init(onEscape: @escaping () -> Void) {
      self.onEscape = onEscape
    }

    func attach(to window: NSWindow?) {
      guard self.window !== window, let window else { return }
      detach()
      self.window = window
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window, event.keyCode == 53 else { return event }
        self.onEscape()
        return nil
      }
    }

    func detach() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      window = nil
    }
  }

  final class EscapeHandlerView: NSView {
    weak var coordinator: Coordinator?

    init(coordinator: Coordinator) {
      self.coordinator = coordinator
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.attach(to: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { coordinator?.detach() }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}
