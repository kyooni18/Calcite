#if canImport(SwiftUI)
import SwiftUI
import EditorVim

/// TextEditor can display/bind VimEngine text, but it does not expose every key event.
/// Use buttons/Commands for method-driven actions, or replace TextEditor with an
/// NSTextView/UITextView representable for complete Vim keyboard interception.
@MainActor
final class VimTextEditorModel: ObservableObject {
  @Published var text: String
  @Published var mode: VimMode
  @Published var cursorUTF16: Int
  let vim: VimEngine

  init(text: String = "") {
    vim = VimEngine(text: text, leader: " ")
    self.text = text
    self.mode = .normal
    self.cursorUTF16 = 0

    vim.mapLeader("ff", to: .action(.host(.custom("findFile"))))
    vim.mapLeader("w", to: .action(.host(.write)))
  }

  func textEditorDidChange(_ newText: String) {
    text = newText
    vim.synchronize(text: newText, cursor: cursorUTF16)
  }

  @discardableResult
  func execute(_ invocation: VimInvocation) -> [VimHostRequest] {
    do {
      let result = try vim.execute(invocation)
      text = result.state.text
      mode = result.state.mode
      cursorUTF16 = result.state.cursor
      return result.hostRequests
    } catch {
      assertionFailure("Vim execution failed: \(error)")
      return []
    }
  }
}

struct VimTextEditorExample: View {
  @StateObject private var model = VimTextEditorModel(text: "hello\n")

  var body: some View {
    VStack(alignment: .leading) {
      Text("-- \(model.mode.rawValue.uppercased()) --")
      TextEditor(text: Binding(
        get: { model.text },
        set: { model.textEditorDidChange($0) }
      ))
      HStack {
        Button("Normal") { model.execute(.action(.escape)) }
        Button("Insert") { model.execute(.action(.enterInsert)) }
        Button("Delete word") { model.execute(.action(.operatorMotion(.delete, .wordForward))) }
        Button("Undo") { model.execute(.action(.undo)) }
      }
    }
  }
}
#endif
