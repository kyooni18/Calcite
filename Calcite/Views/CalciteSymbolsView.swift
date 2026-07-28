import EditorServices
import SwiftUI

/// A layout-hosted table of contents for the document owned by the active editor session.
@MainActor
struct CalciteSymbolsView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    Group {
      if let document = windowSession.selectedDocument {
        CalciteDocumentSymbolsView(
          document: document,
          background: backend.controller.profile.workbench.sidebarBackground.color,
          select: { range in select(range, in: document) }
        )
        .id(document.id)
      } else {
        ContentUnavailableView(
          "No Active Document",
          systemImage: "list.bullet.indent",
          description: Text("Open a document to see its symbols.")
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(backend.controller.profile.workbench.sidebarBackground.color)
  }

  private func select(_ range: EditorTextRange, in document: EditorTab) {
    guard let selection = try? TextSnapshot(text: document.text).nsRange(for: range) else {
      return
    }

    if let editor = windowSession.activeEditorSession,
      editor.documentID == document.id
    {
      editor.updateSelection(selection)
    } else {
      document.updateSelection(selection)
    }
  }
}

@MainActor
private struct CalciteDocumentSymbolsView: View {
  @ObservedObject var document: EditorTab
  let background: Color
  let select: (EditorTextRange) -> Void

  @State private var symbols: [CalciteDocumentSymbolNode] = []
  @State private var query = ""
  @State private var errorMessage: String?
  @State private var isLoading = false
  @State private var refreshID: UInt64 = 0

  private var request: SymbolLoadRequest {
    SymbolLoadRequest(
      documentID: document.id,
      textRevision: document.textRevision,
      refreshID: refreshID
    )
  }

  private var filteredSymbols: [CalciteDocumentSymbolNode] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return symbols }
    return symbols.compactMap { $0.filtered(matching: trimmedQuery) }
  }

  var body: some View {
    VStack(spacing: 0) {
      filterBar
      Divider()
      content
    }
    .task(id: request) {
      await loadSymbols(for: request)
    }
  }

  private var filterBar: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Filter Symbols", text: $query)
        .textFieldStyle(.plain)

      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear symbol filter")
      }

      Button {
        refreshID &+= 1
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .disabled(isLoading)
      .help("Refresh document symbols")
    }
    .padding(.horizontal, 9)
    .frame(height: 30)
    .background(.bar)
  }

  @ViewBuilder
  private var content: some View {
    if symbols.isEmpty, isLoading {
      ProgressView("Loading Symbols…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage, symbols.isEmpty {
      ContentUnavailableView {
        Label("Symbols Unavailable", systemImage: "list.bullet.indent")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try Again") {
          refreshID &+= 1
        }
      }
    } else if symbols.isEmpty {
      ContentUnavailableView(
        "No Symbols",
        systemImage: "list.bullet.indent",
        description: Text("The active document does not report any symbols.")
      )
    } else if filteredSymbols.isEmpty {
      ContentUnavailableView.search(text: query)
    } else {
      List {
        OutlineGroup(filteredSymbols, children: \.children) { node in
          Button {
            select(node.selectionRange)
          } label: {
            HStack(spacing: 7) {
              Image(systemName: node.systemImage)
                .frame(width: 14)
                .foregroundStyle(node.tint)

              VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                  .lineLimit(1)

                if let detail = node.detail {
                  Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }

              Spacer(minLength: 4)

              Text("\(node.line)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(node.accessibilityLabel)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(background)
      .overlay(alignment: .topTrailing) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .padding(8)
        }
      }
    }
  }

  private func loadSymbols(for request: SymbolLoadRequest) async {
    isLoading = true
    errorMessage = nil

    do {
      try await Task.sleep(for: .milliseconds(180))
      let values = try await document.documentSymbols()
      guard
        !Task.isCancelled,
        document.id == request.documentID,
        document.textRevision == request.textRevision,
        refreshID == request.refreshID
      else { return }

      symbols = CalciteDocumentSymbolNode.makeNodes(from: values)
      isLoading = false
    } catch is CancellationError {
      return
    } catch {
      guard
        !Task.isCancelled,
        document.id == request.documentID,
        document.textRevision == request.textRevision,
        refreshID == request.refreshID
      else { return }

      errorMessage = error.localizedDescription
      isLoading = false
    }
  }
}

private struct SymbolLoadRequest: Hashable {
  let documentID: UUID
  let textRevision: UInt64
  let refreshID: UInt64
}

private struct CalciteDocumentSymbolNode: Identifiable {
  let id: String
  let name: String
  let detail: String?
  let kind: EditorSymbolKind
  let selectionRange: EditorTextRange
  let children: [CalciteDocumentSymbolNode]?

  var line: Int { selectionRange.start.line + 1 }

  var accessibilityLabel: String {
    if let detail {
      return "\(name), \(detail), line \(line)"
    }
    return "\(name), line \(line)"
  }

  var systemImage: String {
    switch kind {
    case .file: "doc.text"
    case .module, .namespace, .package: "shippingbox"
    case .class, .interface, .struct, .typeParameter: "cube"
    case .method, .constructor, .function, .operator: "function"
    case .property, .field, .key: "slider.horizontal.3"
    case .enum, .enumMember: "list.bullet.rectangle"
    case .variable, .constant: "textformat.abc"
    case .string: "text.quote"
    case .number: "number"
    case .boolean: "checkmark.circle"
    case .array: "square.stack"
    case .object: "curlybraces"
    case .event: "bolt"
    case .null: "nosign"
    }
  }

  var tint: Color {
    switch kind {
    case .class, .interface, .struct, .enum, .typeParameter:
      .purple
    case .method, .constructor, .function, .operator:
      .blue
    case .property, .field, .variable, .constant, .key, .enumMember:
      .teal
    case .module, .namespace, .package, .file:
      .orange
    case .event:
      .yellow
    case .string, .number, .boolean, .array, .object, .null:
      .secondary
    }
  }

  func filtered(matching query: String) -> CalciteDocumentSymbolNode? {
    let filteredChildren = children?.compactMap { $0.filtered(matching: query) }
    let matchesSelf =
      name.localizedStandardContains(query)
      || detail?.localizedStandardContains(query) == true

    guard matchesSelf || filteredChildren?.isEmpty == false else { return nil }
    return CalciteDocumentSymbolNode(
      id: id,
      name: name,
      detail: detail,
      kind: kind,
      selectionRange: selectionRange,
      children: matchesSelf ? children : filteredChildren
    )
  }

  static func makeNodes(from symbols: [EditorDocumentSymbol]) -> [CalciteDocumentSymbolNode] {
    symbols.enumerated().map { index, symbol in
      makeNode(symbol, path: "\(index)")
    }
  }

  private static func makeNode(
    _ symbol: EditorDocumentSymbol,
    path: String
  ) -> CalciteDocumentSymbolNode {
    let childNodes = symbol.children.enumerated().map { index, child in
      makeNode(child, path: "\(path).\(index)")
    }
    let detail =
      symbol.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? symbol.containerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

    return CalciteDocumentSymbolNode(
      id:
        "\(path):\(symbol.selectionRange.start.line):\(symbol.selectionRange.start.utf16Column):\(symbol.name)",
      name: symbol.name,
      detail: detail,
      kind: symbol.kind,
      selectionRange: symbol.selectionRange,
      children: childNodes.isEmpty ? nil : childNodes
    )
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
