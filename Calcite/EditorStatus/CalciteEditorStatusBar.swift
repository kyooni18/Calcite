@_spi(Calcite) import EditorVim
import Foundation
import SwiftUI

enum CalciteEditorStatusPresentation: Equatable {
  case standard(StandardEditorStatus)
  case vimNormal(VimNormalEditorStatus)
  case vimInsert(VimInsertEditorStatus)
  case vimReplace(VimReplaceEditorStatus)
  case vimVisual(VimVisualEditorStatus)
  case commandLine(EditorCommandLineStatus)
  case transientMessage(EditorStatusMessagePresentation)
}

struct StandardEditorStatus: Equatable {
  var languageID: String
  var isDirty: Bool
}

struct VimNormalEditorStatus: Equatable {
  var label: String
  var pendingNotation: String
  var recordingRegister: Character?
  var isTemporary: Bool
}

struct VimInsertEditorStatus: Equatable {
  var label: String
  var inputSource: String?
  var isComposing: Bool
  var completionIndex: Int?
  var completionCount: Int
  var snippetIndex: Int?
  var snippetCount: Int
  var blockLineCount: Int?
}

struct VimReplaceEditorStatus: Equatable {
  var label: String
  var inputSource: String?
  var isComposing: Bool
}

struct VimVisualEditorStatus: Equatable {
  var label: String
  var characterCount: Int
  var lineCount: Int
  var width: Int?
  var virtualColumnRange: Range<Int>?
}

struct EditorCommandLineStatus: Equatable {
  var snapshot: VimCommandLineSnapshot
  var message: EditorStatusMessagePresentation?
}

struct EditorStatusMessagePresentation: Equatable {
  var code: String?
  var text: String
  var severity: VimMessageSeverity
}

@MainActor
enum CalciteEditorStatusCoordinator {
  static func presentation(
    tab: EditorTab,
    profile: EditorCustomProfile
  ) -> CalciteEditorStatusPresentation {
    guard profile.vim.enabled else {
      return .standard(StandardEditorStatus(languageID: tab.languageID, isDirty: tab.isDirty))
    }

    let interaction = tab.vimInteraction
    let message = tab.vimStatusMessage.map {
      EditorStatusMessagePresentation(code: $0.code, text: $0.text, severity: $0.severity)
    }

    if let commandLine = interaction.commandLine {
      return .commandLine(EditorCommandLineStatus(snapshot: commandLine, message: message))
    }

    if let message {
      return .transientMessage(message)
    }

    switch interaction.mode {
    case .normal:
      return .vimNormal(
        VimNormalEditorStatus(
          label: interaction.isTemporaryNormal ? "INSERT → NORMAL" : "NORMAL",
          pendingNotation: interaction.pendingCommand.notation,
          recordingRegister: interaction.macro.recordingRegister,
          isTemporary: interaction.isTemporaryNormal
        )
      )
    case .insert:
      let block =
        interaction.visualSelection?.shape == .block
        ? interaction.visualSelection : nil
      return .vimInsert(
        VimInsertEditorStatus(
          label:
            if block?.isBlockAppend == true
          {
            "V-BLOCK APPEND"
          } else if block != nil {
            "V-BLOCK INSERT"
          } else {
            "INSERT"
          },
          inputSource: friendlyInputSource(tab.vimInputSourceIdentifier),
          isComposing: interaction.isComposingText,
          completionIndex: tab.completions.isEmpty ? nil : tab.selectedCompletionIndex + 1,
          completionCount: tab.completions.count,
          snippetIndex: tab.snippetProgress?.current,
          snippetCount: tab.snippetProgress?.total ?? 0,
          blockLineCount: block?.height
        )
      )
    case .replace:
      return .vimReplace(
        VimReplaceEditorStatus(
          label: "REPLACE",
          inputSource: friendlyInputSource(tab.vimInputSourceIdentifier),
          isComposing: interaction.isComposingText
        )
      )
    case .visualCharacter, .visualLine:
      if let visual = interaction.visualSelection {
        let label: String
        switch visual.shape {
        case .character: label = "VISUAL"
        case .line: label = "V-LINE"
        case .block: label = "V-BLOCK"
        }
        return .vimVisual(
          VimVisualEditorStatus(
            label: label,
            characterCount: visual.characterCount,
            lineCount: visual.lineCount,
            width: visual.width,
            virtualColumnRange: visual.virtualColumnRange
          )
        )
      }
      let selection = selectionMetrics(tab: tab)
      return .vimVisual(
        VimVisualEditorStatus(
          label: interaction.mode == .visualLine ? "V-LINE" : "VISUAL",
          characterCount: selection.characters,
          lineCount: selection.lines,
          width: nil,
          virtualColumnRange: nil
        )
      )
    case .commandLine, .search:
      // A command-line mode without a session can occur only during a transient
      // synchronization boundary. Keep a stable mode presentation instead of
      // flashing the standard status bar.
      return .vimNormal(
        VimNormalEditorStatus(
          label: interaction.mode == .search ? "SEARCH" : "COMMAND",
          pendingNotation: interaction.pendingCommand.notation,
          recordingRegister: interaction.macro.recordingRegister,
          isTemporary: false
        )
      )
    }
  }

  private static func selectionMetrics(tab: EditorTab) -> (characters: Int, lines: Int) {
    let source = tab.text as NSString
    let location = min(max(0, tab.selectedRange.location), source.length)
    let range = NSRange(
      location: location,
      length: min(max(0, tab.selectedRange.length), source.length - location)
    )
    let selected = source.substring(with: range)
    let characters = selected.count
    guard range.length > 0 else { return (0, 1) }
    let lineRange = source.lineRange(for: range)
    let lineText = source.substring(with: lineRange)
    var lines = 0
    lineText.enumerateLines { _, _ in lines += 1 }
    if lines == 0 { lines = 1 }
    return (characters, lines)
  }

  private static func friendlyInputSource(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    let components = identifier.split(separator: ".")
    guard let last = components.last else { return identifier }
    let previous = components.dropLast().last
    if let previous, ["Korean", "Japanese", "SCIM", "TCIM"].contains(String(previous)) {
      return "\(previous) \(last)"
    }
    return String(last)
  }
}

@MainActor
struct CalciteEditorStatusBar: View {
  @ObservedObject var tab: EditorTab
  let profile: EditorCustomProfile
  let editorMode: EditorInterface
  let onSelectInputMode: (EditorInterface) -> Void

  private var presentation: CalciteEditorStatusPresentation {
    CalciteEditorStatusCoordinator.presentation(tab: tab, profile: profile)
  }

  var body: some View {
    HStack(spacing: 10) {
      statusContent
        .frame(maxWidth: .infinity, alignment: .leading)

      editorModeMenu

      if tab.errorCount > 0 {
        Label("\(tab.errorCount)", systemImage: "xmark.circle")
          .foregroundStyle(.red)
      }
      if tab.warningCount > 0 {
        Label("\(tab.warningCount)", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
      Text("Ln \(tab.currentLine), Col \(tab.currentColumn)")
        .monospacedDigit()
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .background(.bar)
  }

  @ViewBuilder
  private var statusContent: some View {
    switch presentation {
    case .standard(let status):
      HStack(spacing: 8) {
        Text(status.languageID)
        if status.isDirty { Text("Modified").foregroundStyle(.secondary) }
      }
    case .vimNormal(let status):
      HStack(spacing: 8) {
        modeBadge(status.label, color: status.isTemporary ? .orange : .accentColor)
        if let register = status.recordingRegister {
          Text("recording @\(register)")
            .font(.system(.caption, design: .monospaced).weight(.semibold))
        } else if !status.pendingNotation.isEmpty {
          Text(status.pendingNotation)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        Spacer(minLength: 0)
        Text(tab.title).foregroundStyle(.secondary).lineLimit(1)
      }
    case .vimInsert(let status):
      HStack(spacing: 8) {
        modeBadge(status.label, color: .green)
        if let inputSource = status.inputSource { Text(inputSource).foregroundStyle(.secondary) }
        if let blockLineCount = status.blockLineCount {
          Text("\(blockLineCount) lines").foregroundStyle(.secondary)
        }
        if status.isComposing {
          Label("composing", systemImage: "character.cursor.ibeam")
        } else if let snippetIndex = status.snippetIndex {
          Text("Snippet \(snippetIndex)/\(status.snippetCount)")
        } else if let completionIndex = status.completionIndex {
          Text("Completion \(completionIndex)/\(status.completionCount)")
        } else {
          Text(tab.languageID).foregroundStyle(.secondary)
        }
      }
    case .vimReplace(let status):
      HStack(spacing: 8) {
        modeBadge(status.label, color: .orange)
        if let inputSource = status.inputSource { Text(inputSource).foregroundStyle(.secondary) }
        Text(status.isComposing ? "composing" : "overwrite")
      }
    case .vimVisual(let status):
      HStack(spacing: 8) {
        modeBadge(status.label, color: .accentColor)
        if status.label == "V-LINE" {
          Text("\(status.lineCount) lines")
        } else if status.label == "V-BLOCK", let width = status.width {
          Text("\(status.lineCount) × \(width)")
          if let columns = status.virtualColumnRange {
            Text("Col \(columns.lowerBound + 1)–\(columns.upperBound)")
              .foregroundStyle(.secondary)
          }
        } else {
          Text("\(status.characterCount) chars")
          Text("\(status.lineCount) lines").foregroundStyle(.secondary)
        }
      }
    case .commandLine(let status):
      HStack(spacing: 10) {
        VimCommandLineStatusView(snapshot: status.snapshot)
        Spacer(minLength: 8)
        if let message = status.message {
          messageView(message)
        } else if let position = status.snapshot.historyPosition {
          Text("history \(position + 1)/\(status.snapshot.historyCount)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    case .transientMessage(let message):
      messageView(message)
    }
  }

  private var editorModeMenu: some View {
    Menu {
      ForEach(EditorInterface.allCases) { mode in
        Button {
          onSelectInputMode(mode)
        } label: {
          if mode == editorMode {
            Label(mode.title, systemImage: "checkmark")
          } else {
            Text(mode.title)
          }
        }
      }
    } label: {
      Text(editorMode.title.uppercased())
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(profile.vim.enabled ? Color.accentColor : Color.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Choose editor mode")
  }

  private func modeBadge(_ label: String, color: Color) -> some View {
    Text(label)
      .font(.caption.monospaced().weight(.bold))
      .foregroundStyle(color)
  }

  private func messageView(_ message: EditorStatusMessagePresentation) -> some View {
    HStack(spacing: 5) {
      Image(
        systemName: message.severity == .error
          ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
      Text([message.code, message.text].compactMap { $0 }.joined(separator: ": "))
        .lineLimit(1)
    }
    .foregroundStyle(message.severity == .error ? Color.red : Color.orange)
  }
}

private struct VimCommandLineStatusView: View {
  let snapshot: VimCommandLineSnapshot

  private var characters: [Character] { Array(snapshot.text) }
  private var cursor: Int { min(max(0, snapshot.cursorOffset), characters.count) }
  private var before: String { String(characters.prefix(cursor)) }
  private var after: [Character] { Array(characters.dropFirst(cursor)) }

  var body: some View {
    HStack(spacing: 0) {
      Text(snapshot.prefix + before)
      if !snapshot.markedText.isEmpty {
        Text(snapshot.markedText)
          .underline()
          .background(Color.accentColor.opacity(0.12))
        Text(String(after))
      } else if let first = after.first {
        Text(String(first))
          .foregroundStyle(Color(nsColor: .textBackgroundColor))
          .background(Color(nsColor: .textColor))
        Text(String(after.dropFirst()))
      } else {
        Text(" ")
          .foregroundStyle(Color(nsColor: .textBackgroundColor))
          .background(Color(nsColor: .textColor))
      }
    }
    .font(.system(.caption, design: .monospaced))
    .lineLimit(1)
  }
}
