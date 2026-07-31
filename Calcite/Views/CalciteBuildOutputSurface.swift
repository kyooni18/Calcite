import EditorServices
import SwiftUI

#if os(macOS)
  struct CalciteBuildOutputSurface: View {
    enum SurfaceMode: String, CaseIterable, Identifiable {
      case output = "Output"
      case events = "Events"
      case tests = "Tests"
      var id: String { rawValue }
    }

    @ObservedObject var controller: EditorWorkspaceController
    @ObservedObject var buildController: EditorBuildController
    @ObservedObject private var testController: EditorTestController
    @ObservedObject private var eventStore: EditorExecutionEventStore
    @State private var mode: SurfaceMode = .output

    init(controller: EditorWorkspaceController, buildController: EditorBuildController) {
      self.controller = controller
      self.buildController = buildController
      self._testController = ObservedObject(wrappedValue: controller.testController)
      self._eventStore = ObservedObject(wrappedValue: buildController.executionEvents)
    }

    var body: some View {
      VStack(spacing: 0) {
        toolbar
        Divider()
        switch mode {
        case .output:
          rawOutput
        case .events:
          structuredEvents
        case .tests:
          testResults
        }
      }
    }

    private var toolbar: some View {
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
        Menu {
          Button("Run All Tests") { controller.runBuildTask(.test) }
            .disabled(buildController.plan.command(for: .test) == nil)
          Button("Test Current File") { controller.runTestsInCurrentFile() }
            .disabled(
              controller.activeTab == nil || buildController.plan.command(for: .test) == nil)
          Button("Test Current Symbol") { controller.runTestAtCurrentSymbol() }
            .disabled(
              controller.activeTab == nil || buildController.plan.command(for: .test) == nil)
          Button("Debug Tests in Current File") { controller.debugTestsInCurrentFile() }
            .disabled(
              controller.activeTab == nil || buildController.plan.command(for: .test) == nil)
          Button("Debug Current Test Symbol") { controller.debugTestAtCurrentSymbol() }
            .disabled(
              controller.activeTab == nil || buildController.plan.command(for: .test) == nil)
          Button("Test Changed Files") { controller.runTestsForChangedFiles() }
            .disabled(
              controller.recentlyChangedSourceFiles.isEmpty
                || buildController.plan.command(for: .test) == nil
            )
          Button("Rerun Failed Tests") { controller.rerunFailedTests() }
            .disabled(!testController.results.contains { $0.status == .failed })
        } label: {
          Label("Tests", systemImage: "checkmark.diamond")
        }
        .labelStyle(.iconOnly)
        Button("Clear", systemImage: "eraser") {
          switch mode {
          case .output: buildController.clear()
          case .events: eventStore.clear()
          case .tests: testController.clear()
          }
        }
        Picker("View", selection: $mode) {
          ForEach(SurfaceMode.allCases) { value in
            Text(value.rawValue).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
        Spacer()
        BuildPhaseView(phase: buildController.phase)
      }
      .padding(.horizontal, 8)
      .frame(height: 32)
      .background(.bar)
    }

    private var rawOutput: some View {
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

    private var structuredEvents: some View {
      VStack(spacing: 0) {
        HStack(spacing: 5) {
          ForEach(EditorExecutionChannel.allCases, id: \.self) { channel in
            Toggle(
              channel.rawValue,
              isOn: Binding(
                get: { eventStore.selectedChannels.contains(channel) },
                set: { enabled in
                  if enabled {
                    eventStore.selectedChannels.insert(channel)
                  } else {
                    eventStore.selectedChannels.remove(channel)
                  }
                }
              )
            )
            .toggleStyle(.button)
            .controlSize(.small)
          }
          Spacer()
          Toggle("Follow", isOn: $eventStore.followsLatestOutput)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(.bar.opacity(0.65))

        ScrollViewReader { proxy in
          List(eventStore.visibleEvents) { event in
            Button {
              if let location = event.sourceLocation {
                controller.openExecutionSource(location)
              }
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.tertiary)
                Text(event.channel.rawValue.uppercased())
                  .font(.caption2.monospaced().weight(.semibold))
                  .foregroundStyle(color(for: event.severity))
                  .frame(width: 72, alignment: .leading)
                Text(event.text.trimmingCharacters(in: .newlines))
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(event.sourceLocation == nil)
            .id(event.id)
          }
          .onChange(of: eventStore.events.count) { _, _ in
            guard eventStore.followsLatestOutput, let last = eventStore.visibleEvents.last else {
              return
            }
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }

    private var testResults: some View {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text(testController.lastScopeDescription)
            .font(.caption.weight(.medium))
          Text(testSummary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.bar.opacity(0.65))

        List(testController.results) { result in
          Button {
            if let location = result.failureLocation {
              controller.openExecutionSource(location)
            }
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: testSymbol(result.status))
                .foregroundStyle(testColor(result.status))
              VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                  .font(.body.weight(.medium))
                HStack(spacing: 8) {
                  Text(result.suite).font(.caption).foregroundStyle(.secondary)
                  if let duration = result.durationSeconds {
                    Text(String(format: "%.3fs", duration))
                      .font(.caption.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }
                }
                if let message = result.message {
                  Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                }
              }
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(result.failureLocation == nil)
        }
        .overlay {
          if testController.results.isEmpty {
            ContentUnavailableView(
              "No Test Results",
              systemImage: "checkmark.diamond",
              description: Text("Run a detected test task to populate structured results.")
            )
          }
        }
      }
    }

    private var testSummary: String {
      let passed = testController.results.count { $0.status == .passed }
      let failed = testController.results.count { $0.status == .failed }
      let skipped = testController.results.count { $0.status == .skipped }
      return "\(passed) passed · \(failed) failed · \(skipped) skipped"
    }

    private func color(for severity: EditorExecutionSeverity) -> Color {
      switch severity {
      case .trace, .info: return .secondary
      case .notice: return .accentColor
      case .warning: return .orange
      case .error: return .red
      }
    }

    private func testSymbol(_ status: EditorTestStatus) -> String {
      switch status {
      case .passed: return "checkmark.circle.fill"
      case .failed: return "xmark.circle.fill"
      case .skipped: return "minus.circle.fill"
      case .cancelled: return "stop.circle.fill"
      case .unknown: return "questionmark.circle"
      }
    }

    private func testColor(_ status: EditorTestStatus) -> Color {
      switch status {
      case .passed: return .green
      case .failed: return .red
      case .skipped, .cancelled, .unknown: return .secondary
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
