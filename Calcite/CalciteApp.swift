import SwiftUI

@main
struct CalciteApp: App {
  @StateObject private var recents = EditorRecentItemsStore()
  @AppStorage("interfaceScale") private var interfaceScale = 1.0
  @AppStorage("editorAppearanceMode") private var appearanceModeRaw =
    EditorInterfaceAppearance.system.rawValue

  private var appearanceMode: EditorInterfaceAppearance {
    EditorInterfaceAppearance(rawValue: appearanceModeRaw) ?? .system
  }

  var body: some Scene {
    WindowGroup {
      ContentView(interfaceScale: $interfaceScale)
        .environmentObject(recents)
        .preferredColorScheme(appearanceMode.colorScheme)
    }
    .restorationBehavior(.disabled)
    .commands {
      CalciteApplicationCommands(recents: recents)
      EditorEditCommands()
      EditorProjectCommands()
      EditorTerminalCommands()
    }
  }
}
