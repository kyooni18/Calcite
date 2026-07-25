import EditorServices
import SwiftUI

#if os(macOS)
  struct CalciteDebugPanelSurface: View {
    @ObservedObject var controller: EditorWorkspaceController

    var body: some View {
      HSplitView {
        VStack(spacing: 0) {
          debugControls
          List(controller.debugFrames, id: \.id) { frame in
            Button {
              controller.selectDebugFrame(frame)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(frame.name).lineLimit(1)
                Text(
                  "\(frame.source?.name ?? frame.source?.path ?? "Unknown source"):\(frame.line)"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
              controller.selectedDebugFrameID == frame.id
                ? Color.accentColor.opacity(0.15) : Color.clear
            )
          }
          .overlay {
            if controller.debugFrames.isEmpty {
              ContentUnavailableView(
                "No Stack Frames",
                systemImage: "square.stack.3d.up",
                description: Text("Frames appear when the debugger stops.")
              )
            }
          }
        }
        .frame(minWidth: 260)

        List {
          ForEach(controller.debugScopes) { snapshot in
            Section(snapshot.scope.name) {
              ForEach(Array(snapshot.variables.enumerated()), id: \.offset) { _, variable in
                VStack(alignment: .leading, spacing: 2) {
                  HStack {
                    Text(variable.name).fontWeight(.medium)
                    Spacer()
                    if let type = variable.type {
                      Text(type).font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Text(variable.value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                }
              }
            }
          }
        }
        .overlay {
          if controller.debugScopes.isEmpty {
            ContentUnavailableView(
              "No Variables",
              systemImage: "list.bullet.rectangle",
              description: Text("Variables appear for the selected stack frame.")
            )
          }
        }
        .frame(minWidth: 300)
      }
    }

    private var debugControls: some View {
      HStack(spacing: 6) {
        Button("Start", systemImage: "ladybug") { controller.startDebugging() }
          .disabled(debugSessionIsActive || controller.activeTab == nil)
        Button("Continue", systemImage: "play.fill") { controller.continueDebugging() }
          .disabled(!debugSessionIsStopped)
        Button("Pause", systemImage: "pause.fill") { controller.pauseDebugging() }
          .disabled(!debugSessionIsRunning)
        Button("Step Over", systemImage: "arrow.turn.down.right") { controller.stepOver() }
          .disabled(!debugSessionIsStopped)
        Button("Step Into", systemImage: "arrow.down.to.line") { controller.stepInto() }
          .disabled(!debugSessionIsStopped)
        Button("Step Out", systemImage: "arrow.up.to.line") { controller.stepOut() }
          .disabled(!debugSessionIsStopped)
        Button("Stop", systemImage: "stop.fill") { controller.stopDebugging() }
          .disabled(!debugSessionIsActive)
        Spacer()
        Text(debugPhaseText).font(.caption).foregroundStyle(.secondary)
      }
      .labelStyle(.iconOnly)
      .padding(.horizontal, 8)
      .frame(height: 32)
      .background(.bar)
    }

    private var debugSessionIsActive: Bool {
      switch controller.debugPhase {
      case .starting, .running, .stopped: return true
      case .idle, .failed: return false
      }
    }

    private var debugSessionIsRunning: Bool {
      if case .running = controller.debugPhase { return true }
      return false
    }

    private var debugSessionIsStopped: Bool {
      if case .stopped = controller.debugPhase { return true }
      return false
    }

    private var debugPhaseText: String {
      switch controller.debugPhase {
      case .idle: return "Idle"
      case .starting: return "Starting"
      case .running: return "Running"
      case .stopped: return "Stopped"
      case .failed(let message): return message
      }
    }
  }

#endif
