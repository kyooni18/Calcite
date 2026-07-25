#if os(macOS)
  import EditorServices
  import SwiftUI

  struct CalciteTerminalSurface: View {
    @ObservedObject var session: EditorTerminalSession
    let themeProfile: EditorTerminalProfile?
    @StateObject private var appearanceStore = EditorTerminalPreferencesStore()
    @State private var showsSettings = false

    var body: some View {
      VStack(spacing: 0) {
        TerminalToolbar(
          session: session,
          openSettings: {
            appearanceStore.refresh()
            showsSettings = true
          }
        )
        Divider()
        TerminalTextView(
          snapshot: session.renderedSnapshot,
          outputEpoch: session.outputEpoch,
          preferences: appearanceStore.preferences,
          appearanceRevision: appearanceStore.revision,
          send: session.send,
          clear: session.clear,
          resize: session.resize
        )
      }
      .onAppear {
        if let themeProfile {
          appearanceStore.apply(theme: themeProfile)
        } else {
          appearanceStore.refresh()
        }
        session.reattachView()
      }
      .onDisappear {
        session.detachView()
      }
      .onChange(of: themeProfile) { _, value in
        if let value { appearanceStore.apply(theme: value) }
      }
      .sheet(isPresented: $showsSettings) {
        TerminalSettingsView(store: appearanceStore)
      }
    }
  }

  private struct TerminalToolbar: View {
    @ObservedObject var session: EditorTerminalSession
    let openSettings: () -> Void

    var body: some View {
      HStack(spacing: 8) {
        Circle()
          .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.55))
          .frame(width: 7, height: 7)
        Text(URL(fileURLWithPath: session.shellPath).lastPathComponent)
          .font(.caption.monospaced().weight(.medium))
        Text(session.workspaceURL.lastPathComponent)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        if let python = session.pythonEnvironment {
          Label(python.name, systemImage: "chevron.left.forwardslash.chevron.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(python.rootURL.path)
        }

        Spacer()

        if let status = session.exitDescription {
          Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        terminalButton("Style", symbol: "textformat") { openSettings() }
        terminalButton("External", symbol: "arrow.up.forward.app") {
          session.openExternalTerminal()
        }
        terminalButton("Clear", symbol: "eraser") { session.clear() }
        terminalButton("Restart", symbol: "arrow.clockwise") { session.restart() }
          .disabled(session.isStopping)
        terminalButton("Stop", symbol: "stop.fill") { session.stop() }
          .disabled(!session.isRunning)
      }
      .padding(.horizontal, 9)
      .frame(height: 30)
      .background(.bar)
    }

    private func terminalButton(
      _ title: String,
      symbol: String,
      action: @escaping () -> Void
    ) -> some View {
      Button(title, systemImage: symbol, action: action)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .help(title)
        .frame(width: 22, height: 22)
    }
  }
#endif
