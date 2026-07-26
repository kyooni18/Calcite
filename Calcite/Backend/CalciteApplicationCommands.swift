import AppKit
import SwiftUI

struct CalciteApplicationCommands: Commands {
  @ObservedObject var recents: EditorRecentItemsStore
  @FocusedValue(\.appCommandHandler) private var appHandler
  @FocusedValue(\.editorCommandHandler) private var editorHandler
  @FocusedValue(\.editorCommandAvailability) private var availability

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        editorHandler?.perform(.openSettings)
      }
      .keyboardShortcut(",", modifiers: .command)
      .disabled(editorHandler == nil)

      Button("Theme Builder…") {
        editorHandler?.perform(.openThemeBuilder)
      }
      .disabled(editorHandler == nil)
    }

    CommandGroup(replacing: .undoRedo) {
      Button("Undo") {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
      }
      .keyboardShortcut("z", modifiers: .command)

      Button("Redo") {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    CommandGroup(after: .newItem) {
      Button("New Project…") {
        appHandler?.perform(.newProject)
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(appHandler == nil)

      Button("Open Project…") {
        appHandler?.perform(.openProject)
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(appHandler == nil)

      Button("Open File…") {
        appHandler?.perform(.openItem)
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      .disabled(appHandler == nil)

      Divider()
      Menu("Open Recent") {
        if recents.items.isEmpty {
          Text("No Recent Items")
        } else {
          ForEach(recents.items, id: \.path) { url in
            Button(url.lastPathComponent) {
              appHandler?.perform(.openRecent(url))
            }
          }
          Divider()
          Button("Clear Recent Items") { recents.clear() }
        }
      }
      .disabled(appHandler == nil)

      Button("Close Project") {
        appHandler?.perform(.closeProject)
      }
      .disabled(appHandler == nil)

      Divider()
    }

    CommandGroup(replacing: .saveItem) {
      Button("Save") {
        editorHandler?.perform(.save)
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(editorHandler == nil || availability?.canSave != true)

      Button("Save All") {
        editorHandler?.perform(.saveAll)
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      .disabled(editorHandler == nil || availability?.canSaveAll != true)
    }

    CommandMenu("Navigate") {
      Button("Go to Definition") {
        editorHandler?.perform(.goToDefinition)
      }
      .keyboardShortcut("d", modifiers: [.command, .control])
      .disabled(editorHandler == nil || availability?.hasDocument != true)

      Button("Find References") {
        editorHandler?.perform(.findReferences)
      }
      .keyboardShortcut("r", modifiers: [.command, .control])
      .disabled(editorHandler == nil || availability?.hasDocument != true)

      Button("Quick Help") {
        editorHandler?.perform(.showQuickHelp)
      }
      .keyboardShortcut("h", modifiers: [.command, .control])
      .disabled(editorHandler == nil || availability?.hasDocument != true)
    }

    CommandMenu("View") {
      Button("Toggle Sidebar") {
        editorHandler?.perform(.toggleSidebar)
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(editorHandler == nil)

      Divider()

      Button("Toggle Hidden Files") {
        editorHandler?.perform(.toggleHiddenFiles)
      }
      .keyboardShortcut(".", modifiers: [.command, .shift])
      .disabled(editorHandler == nil)

      Button("Toggle Git-Ignored Files") {
        editorHandler?.perform(.toggleIgnoredFiles)
      }
      .disabled(editorHandler == nil)

      Button("Toggle Build Artifacts") {
        editorHandler?.perform(.toggleBuildArtifacts)
      }
      .disabled(editorHandler == nil)

      Button("Toggle .DS_Store") {
        editorHandler?.perform(.toggleDSStore)
      }
      .disabled(editorHandler == nil)

      Divider()

      Button("Zoom In") {
        editorHandler?.perform(.zoomIn)
      }
      .keyboardShortcut("=", modifiers: [.command, .shift])
      .disabled(editorHandler == nil || availability?.hasDocument != true)

      Button("Zoom Out") {
        editorHandler?.perform(.zoomOut)
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(editorHandler == nil || availability?.hasDocument != true)

      Button("Actual Size") {
        editorHandler?.perform(.resetZoom)
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(editorHandler == nil || availability?.hasDocument != true)
    }
  }
}
