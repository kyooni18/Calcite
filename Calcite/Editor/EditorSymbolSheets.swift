import EditorServices
import SwiftUI

struct EditorSymbolInformationPopover: View {
  let information: EditorSymbolInformation
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Image(systemName: "questionmark.circle")
        Text(information.title)
          .font(.headline)
        Spacer()
        Button(action: dismiss.callAsFunction) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close Quick Help")
      }
      .padding(14)

      Divider()

      ScrollView {
        MarkdownText(information.markdown)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }
    }
    .frame(minWidth: 360, idealWidth: 480, maxWidth: 620, minHeight: 180, idealHeight: 340, maxHeight: 520)
    .background { CalciteBackground() }
    .onExitCommand { dismiss() }
  }
}

private struct MarkdownText: View {
  let markdown: String

  init(_ markdown: String) {
    self.markdown = markdown
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .markdown(let value):
          Text(attributedMarkdown(value))
            .font(.body)
            .multilineTextAlignment(.leading)
        case .code(let language, let value):
          VStack(alignment: .leading, spacing: 4) {
            if !language.isEmpty {
              Text(language.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Text(value)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(10)
          .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
  }

  private enum Block {
    case markdown(String)
    case code(language: String, value: String)
  }

  private var blocks: [Block] {
    var result: [Block] = []
    var markdownLines: [String] = []
    var codeLines: [String] = []
    var language = ""
    var inCode = false

    func flushMarkdown() {
      guard !markdownLines.isEmpty else { return }
      result.append(.markdown(markdownLines.joined(separator: "\n")))
      markdownLines.removeAll()
    }

    for line in markdown.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        if inCode {
          result.append(.code(language: language, value: codeLines.joined(separator: "\n")))
          codeLines.removeAll()
          language = ""
        } else {
          flushMarkdown()
          language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        inCode.toggle()
      } else if inCode {
        codeLines.append(line)
      } else {
        markdownLines.append(line)
      }
    }

    if inCode {
      markdownLines.append("```")
      markdownLines.append(contentsOf: codeLines)
    }
    flushMarkdown()
    return result
  }

  private func attributedMarkdown(_ value: String) -> AttributedString {
    (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full)))
      ?? AttributedString(value)
  }
}

struct EditorSymbolLocationsSheet: View {
  let collection: EditorSymbolLocationCollection
  let workspaceURL: URL
  let open: (SourceLocation) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "list.bullet.rectangle")
        Text(collection.title)
          .font(.headline)
        Spacer()
        Text("\(collection.locations.count)")
          .foregroundStyle(.secondary)
        Button("Done") { dismiss() }
      }
      .padding(14)

      Divider()

      List(collection.locations, id: \.self) { location in
        Button {
          dismiss()
          open(location)
        } label: {
          HStack(spacing: 10) {
            CIcon(code: location.uri.pathExtension.lowercased(), size: 14)
            VStack(alignment: .leading, spacing: 2) {
              Text(location.uri.lastPathComponent)
              Text(locationDescription(location))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
    }
    .frame(minWidth: 560, idealWidth: 720, minHeight: 340, idealHeight: 520)
    .background { CalciteBackground() }
  }

  private func locationDescription(_ location: SourceLocation) -> String {
    let root = workspaceURL.standardizedFileURL.path
    let path = location.uri.standardizedFileURL.path
    let relativePath =
      path.hasPrefix(root + "/")
      ? String(path.dropFirst(root.count + 1))
      : path
    return
      "\(relativePath):\(location.range.start.line + 1):\(location.range.start.utf16Column + 1)"
  }
}
