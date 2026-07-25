import EditorServices
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  struct EditorProblemsView: View {
    private enum ProblemSelection: Hashable {
      case document(tabID: UUID, diagnosticOffset: Int)
      case build(EditorBuildDiagnostic)
    }

    @ObservedObject var controller: EditorWorkspaceController
    @ObservedObject var buildController: EditorBuildController
    @State private var selection: Set<ProblemSelection> = []

    var body: some View {
      List(selection: $selection) {
        ForEach(controller.tabs) { tab in
          if !tab.diagnostics.isEmpty {
            Section(tab.title) {
              ForEach(Array(tab.diagnostics.enumerated()), id: \.offset) { offset, diagnostic in
                ProblemRow(
                  severity: diagnostic.severity,
                  message: diagnostic.message,
                  location: diagnostic.source ?? tab.languageID
                )
                .tag(ProblemSelection.document(tabID: tab.id, diagnosticOffset: offset))
                .onTapGesture(count: 2) {
                  reveal(diagnostic, in: tab)
                }
              }
            }
          }
        }
        if !buildController.diagnostics.isEmpty {
          Section("Build") {
            ForEach(buildController.diagnostics, id: \.self) { diagnostic in
              ProblemRow(
                severity: diagnostic.severity,
                message: diagnostic.message,
                location:
                  "\(diagnostic.url.lastPathComponent):\(diagnostic.line):\(diagnostic.column)"
              )
              .tag(ProblemSelection.build(diagnostic))
              .onTapGesture(count: 2) {
                controller.openBuildDiagnostic(diagnostic)
              }
            }
          }
        }
        if controller.tabs.allSatisfy({ $0.diagnostics.isEmpty })
          && buildController.diagnostics.isEmpty
        {
          ContentUnavailableView(
            "No Problems",
            systemImage: "checkmark.circle",
            description: Text("Build and language-service diagnostics appear here.")
          )
        }
      }
      .listStyle(.inset)
      .onCopyCommand(perform: {
        let text = copiedProblems
        guard !text.isEmpty else { return [] }
        return [NSItemProvider(object: text as NSString)]
      })
    }

    private var copiedProblems: String {
      selection.compactMap { item in
        switch item {
        case .document(let tabID, let offset):
          guard let tab = controller.tabs.first(where: { $0.id == tabID }),
            tab.diagnostics.indices.contains(offset)
          else { return nil }
          let diagnostic = tab.diagnostics[offset]
          return "\(tab.title):\(diagnostic.range.start.line + 1): \(diagnostic.message)"
        case .build(let diagnostic):
          return "\(diagnostic.url.lastPathComponent):\(diagnostic.line):\(diagnostic.column): \(diagnostic.message)"
        }
      }
      .sorted()
      .joined(separator: "\n")
    }

    private func reveal(_ diagnostic: Diagnostic, in tab: EditorTab) {
      let snapshot = TextSnapshot(text: tab.text)
      if let range = try? snapshot.nsRange(for: diagnostic.range) {
        tab.updateSelection(range)
      }
    }
  }

  struct ProblemRow: View {
    let severity: Diagnostic.Severity
    let message: String
    let location: String

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(color)
        VStack(alignment: .leading, spacing: 2) {
          Text(message)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(location)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }

    private var symbol: String {
      switch severity {
      case .error: return "xmark.circle.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .information: return "info.circle.fill"
      case .hint: return "lightbulb.fill"
      }
    }

    private var color: Color {
      switch severity {
      case .error: return .red
      case .warning: return .orange
      case .information: return .blue
      case .hint: return .secondary
      }
    }
  }

#endif
