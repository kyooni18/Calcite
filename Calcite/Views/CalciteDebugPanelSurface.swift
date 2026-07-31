import EditorServices
import SwiftUI

#if os(macOS)
  struct CalciteDebugPanelSurface: View {
    @State private var showsRunConfigurations = false
    @ObservedObject var controller: EditorWorkspaceController
    @ObservedObject private var breakpointController: EditorBreakpointCoordinator
    @ObservedObject private var debugSessionController: EditorDebugSessionController
    @ObservedObject private var liveDebugController: EditorLiveDebugController
    @ObservedObject private var terminalRegistry = EditorTerminalSessionRegistry.shared

    init(controller: EditorWorkspaceController) {
      self.controller = controller
      self._breakpointController = ObservedObject(wrappedValue: controller.breakpointController)
      self._debugSessionController = ObservedObject(wrappedValue: controller.debugSessionController)
      self._liveDebugController = ObservedObject(wrappedValue: controller.liveDebugController)
    }

    var body: some View {
      VStack(spacing: 0) {
        debugControls
        HSplitView {
          VSplitView {
            stackFrames
              .frame(minHeight: 160)
            CalciteBreakpointListView(
              coordinator: breakpointController,
              workspaceURL: controller.workspaceURL,
              update: controller.updateBreakpoint,
              remove: controller.removeBreakpoint
            )
            .frame(minHeight: 140)
          }
          .frame(minWidth: 280)

          VSplitView {
            variableList
              .frame(minHeight: 180)
            if let debugTerminal = terminalRegistry.activeDebugSession(
              for: controller.workspaceURL
            ) {
              CalciteTerminalSurface(
                session: debugTerminal,
                themeProfile: controller.profile.terminal,
                navigateSection: { _ in },
                navigateTab: { _ in },
                selectTab: { _ in },
                handleHostCommand: { _ in }
              )
              .frame(minHeight: 150)
            }
          }
          .frame(minWidth: 300)
        }
      }
    }

    private var stackFrames: some View {
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

    private var variableList: some View {
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
    }

    private var debugControls: some View {
      HStack(spacing: 6) {
        Button("Start Project Debug", systemImage: "ladybug") {
          controller.startDebugging()
        }
        .disabled(debugSessionIsActive)
        Button("Debug Current File", systemImage: "doc.text.magnifyingglass") {
          controller.startDebuggingCurrentFile()
        }
        .disabled(debugSessionIsActive || !controller.commandAvailability.canDebugCurrentFile)
        Menu {
          Button("Live Debug Project") { controller.startLiveDebugging() }
          Button("Live Debug Current File") { controller.startLiveDebuggingCurrentFile() }
            .disabled(!controller.commandAvailability.canDebugCurrentFile)
          Divider()
          Button("Stop Live Debug") { controller.stopLiveDebugging() }
            .disabled(!controller.isLiveDebugEnabled)
        } label: {
          Label(
            controller.isLiveDebugEnabled ? "Live Debug Enabled" : "Live Debug",
            systemImage: controller.isLiveDebugEnabled
              ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
          )
        }
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
        Button("Run Configurations", systemImage: "gearshape") {
          showsRunConfigurations = true
        }
        Spacer()
        if let breakpointStatusText {
          Text(breakpointStatusText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(rejectedBreakpointCount > 0 ? .orange : .secondary)
        }
        if controller.isLiveDebugEnabled {
          Text(liveDebugPhaseText).font(.caption).foregroundStyle(.secondary)
        }
        Text(debugPhaseText).font(.caption).foregroundStyle(.secondary)
      }
      .labelStyle(.iconOnly)
      .padding(.horizontal, 8)
      .frame(height: 32)
      .background(.bar)
      .sheet(isPresented: $showsRunConfigurations) {
        CalciteRunConfigurationView(controller: controller.runConfigurationController)
      }
    }

    private var debugSessionIsActive: Bool {
      switch debugSessionController.phase {
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

    private var breakpointVerification: [Breakpoint] {
      controller.debugBreakpointVerification.values.flatMap { $0 }
    }

    private var rejectedBreakpointCount: Int {
      breakpointVerification.lazy.filter { !$0.verified }.count
    }

    private var breakpointStatusText: String? {
      let values = breakpointVerification
      guard !values.isEmpty else { return nil }
      let verified = values.lazy.filter(\.verified).count
      return rejectedBreakpointCount == 0
        ? "\(verified) breakpoints verified"
        : "\(verified) verified · \(rejectedBreakpointCount) rejected"
    }

    private var liveDebugPhaseText: String {
      switch liveDebugController.phase {
      case .disabled: return "Live Off"
      case .watching: return "Watching"
      case .changesPending(let count): return "\(count) changes pending"
      case .building: return "Live Build"
      case .restarting: return "Restarting"
      case .failed(let message): return "Live: \(message)"
      }
    }

    private var debugPhaseText: String {
      switch debugSessionController.phase {
      case .idle: return "Idle"
      case .starting: return "Starting"
      case .running: return "Running"
      case .stopped: return "Stopped"
      case .failed(let message): return message
      }
    }
  }
#endif
