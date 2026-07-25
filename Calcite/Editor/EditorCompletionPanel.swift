import EditorServices
import SwiftUI

struct EditorCompletionPanel: View {
  static let preferredWidth: CGFloat = 320

  let completions: [Completion]
  let selectedIndex: Int
  let apply: (Completion) -> Void

  static func preferredHeight(for count: Int) -> CGFloat {
    min(CGFloat(count) * 38, 260)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(completions.enumerated()), id: \.offset) { index, completion in
            Button {
              apply(completion)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: completionSymbol(completion.kind))
                  .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                  Text(completion.label)
                    .lineLimit(1)
                  if let detail = completion.detail, !detail.isEmpty {
                    Text(detail)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer(minLength: 8)
              }
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .contentShape(Rectangle())
              .background(
                index == selectedIndex
                  ? Color.accentColor.opacity(0.18)
                  : Color.clear
              )
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
      }
      .onChange(of: selectedIndex) { _, index in
        proxy.scrollTo(index, anchor: .center)
      }
    }
    .frame(
      width: Self.preferredWidth,
      height: Self.preferredHeight(for: completions.count)
    )
    .background {
      CalciteBackground(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color(nsColor: .separatorColor).opacity(0.7))
    )
    .shadow(radius: 8, y: 3)
  }

  private func completionSymbol(_ kind: CompletionKind?) -> String {
    switch kind {
    case .method, .function, .constructor: return "function"
    case .class, .interface, .struct, .enum, .typeParameter: return "cube"
    case .variable, .field, .property, .constant: return "v.square"
    case .module, .file, .folder: return "folder"
    case .keyword, .snippet: return "text.badge.plus"
    default: return "text.cursor"
    }
  }
}
