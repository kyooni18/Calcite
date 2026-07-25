import EditorServices
import SwiftUI

#if os(macOS)
  struct CalciteBuildOutputSurface: View {
    @ObservedObject var controller: EditorWorkspaceController
    @ObservedObject var buildController: EditorBuildController

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Text(buildController.plan.projectKind.rawValue)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Picker("Task", selection: $buildController.selectedCommandID) {
            ForEach(buildController.plan.commands) { command in
              Text(command.title).tag(Optional(command.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: 180)
          .disabled(buildController.phase.isRunning || controller.isPreparingBuildTask)
          Button("Run", systemImage: "play.fill") {
            controller.runSelectedBuildTask()
          }
          .disabled(
            buildController.selectedCommand == nil
              || buildController.phase.isRunning
              || controller.isPreparingBuildTask
          )
          Button("Cancel", systemImage: "stop.fill") {
            controller.cancelBuildTask()
          }
          .disabled(!buildController.phase.isRunning && !controller.isPreparingBuildTask)
          Button("Clear", systemImage: "eraser") { buildController.clear() }
          Spacer()
          BuildPhaseView(phase: buildController.phase)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.bar)

        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            ScrollView(.horizontal) {
              Text(
                buildController.output.isEmpty
                  ? "Build output will appear here." : buildController.output
              )
              .font(.system(size: 11.5, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: true, vertical: false)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(8)
            }
            Color.clear
              .frame(height: 1)
              .id("build-output-end")
          }
          .onChange(of: buildController.output) { _, _ in
            proxy.scrollTo("build-output-end", anchor: .bottom)
          }
        }
      }
    }
  }

  struct BuildPhaseView: View {
    let phase: EditorBuildPhase

    var body: some View {
      switch phase {
      case .idle:
        Text("Idle").foregroundStyle(.secondary)
      case .running(let title):
        HStack(spacing: 5) {
          ProgressView().controlSize(.small)
          Text(title)
        }
      case .cancelling(let title):
        HStack(spacing: 5) {
          ProgressView().controlSize(.small)
          Text("Cancelling \(title)…")
        }
        .foregroundStyle(.secondary)
      case .cancelled(let message):
        Label(message, systemImage: "stop.circle").foregroundStyle(.secondary)
      case .succeeded(let message):
        Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
      case .failed(let message):
        Label(message, systemImage: "xmark.circle").foregroundStyle(.red)
      }
    }
  }
#endif
