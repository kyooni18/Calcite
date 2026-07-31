import SwiftUI

#if os(macOS)
  struct CalciteRunConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: EditorRunConfigurationController
    @State private var draft: EditorRunConfiguration?
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var watchRootsText = ""
    @State private var exclusionsText = ""

    var body: some View {
      NavigationSplitView {
        List(selection: $controller.selectedID) {
          ForEach(controller.configurations) { configuration in
            Label(
              configuration.name,
              systemImage: configuration.target == .project ? "shippingbox" : "doc"
            )
            .tag(Optional(configuration.id))
            .contextMenu {
              Button("Duplicate") { controller.duplicate(configuration) }
              Button("Delete", role: .destructive) { controller.remove(configuration) }
                .disabled(controller.configurations.count <= 1)
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          HStack {
            Menu {
              Button("Project Configuration") { select(controller.add(target: .project)) }
              Button("Current File Configuration") {
                select(controller.add(target: .currentFile))
              }
            } label: {
              Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            Button {
              if let value = draft { controller.remove(value) }
              loadSelected()
            } label: {
              Image(systemName: "minus")
            }
            .disabled(controller.configurations.count <= 1)
            Spacer()
          }
          .padding(8)
          .background(.bar)
        }
        .frame(minWidth: 220)
      } detail: {
        if let draft {
          configurationForm(draft)
        } else {
          ContentUnavailableView("No Configuration", systemImage: "play.rectangle")
        }
      }
      .frame(minWidth: 850, minHeight: 600)
      .onAppear { loadSelected() }
      .onChange(of: controller.selectedID) { _, _ in loadSelected() }
    }

    @ViewBuilder
    private func configurationForm(_ value: EditorRunConfiguration) -> some View {
      Form {
        Section("Identity") {
          TextField("Name", text: draftBinding(\.name, fallback: "Configuration"))
          Picker("Target", selection: draftBinding(\.target, fallback: .project)) {
            Text("Project").tag(EditorExecutionTargetKind.project)
            Text("Current File").tag(EditorExecutionTargetKind.currentFile)
          }
          if value.target == .project {
            TextField(
              "Product / Target / Scheme",
              text: optionalDraftBinding(\.projectTargetName)
            )
            Text(
              "For SwiftPM this selects an executable product, for Cargo a binary, and for Xcode a scheme."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Toggle(
            "Share Configuration with Workspace",
            isOn: draftBinding(\.isShared, fallback: false)
          )
          Text(
            "Shared launch settings are written to .calcite/run-configurations.json. "
              + "Environment values, local paths, and adapter overrides remain private."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Section("Launch") {
          TextField("Arguments", text: $argumentsText)
            .font(.system(.body, design: .monospaced))
          TextField(
            "Working Directory",
            text: draftBinding(\.workingDirectory, fallback: "")
          )
          TextField(
            "Toolchain Directory",
            text: optionalDraftBinding(\.toolchainPath)
          )
          Text(
            "Use a local toolchain root or bin directory. It remains in private workspace settings."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Picker("Terminal", selection: draftBinding(\.terminalMode, fallback: .integrated)) {
            Text("Integrated Terminal").tag(EditorTerminalMode.integrated)
            Text("External Terminal").tag(EditorTerminalMode.external)
            Text("Debug Console").tag(EditorTerminalMode.debugConsole)
          }
          Toggle(
            "Build Before Launch",
            isOn: draftBinding(\.buildBeforeLaunch, fallback: true)
          )
          Toggle("Stop on Entry", isOn: draftBinding(\.stopOnEntry, fallback: false))
          TextField(
            "Debugger Adapter Override",
            text: optionalDraftBinding(\.debuggerAdapterID)
          )
        }

        Section("Environment") {
          TextEditor(text: $environmentText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 110)
          Text("One KEY=value entry per line. Values remain in the local workspace settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Tasks") {
          TextField(
            "Pre-launch Task IDs",
            text: arrayDraftBinding(\.preLaunchTaskIDs)
          )
          TextField(
            "Post-debug Task IDs",
            text: arrayDraftBinding(\.postDebugTaskIDs)
          )
        }

        Section("Live Debug") {
          Text("Watch Roots")
          TextEditor(text: $watchRootsText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 70)
          Text("Exclude Patterns")
          TextEditor(text: $exclusionsText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 90)
        }
      }
      .formStyle(.grouped)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Close") { dismiss() }
          Spacer()
          Button("Revert") { loadSelected() }
          Button("Save") { saveDraft() }
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(.bar)
      }
      .navigationTitle(value.name)
    }

    private func loadSelected() {
      guard
        let value = controller.configuration(id: controller.selectedID ?? UUID())
          ?? controller.configurations.first
      else {
        draft = nil
        return
      }
      select(value)
    }

    private func select(_ value: EditorRunConfiguration) {
      controller.selectedID = value.id
      draft = value
      argumentsText = value.arguments.map(shellQuote).joined(separator: " ")
      environmentText = value.environment.keys.sorted().map {
        "\($0)=\(value.environment[$0] ?? "")"
      }.joined(separator: "\n")
      watchRootsText = value.liveDebugWatchRoots.joined(separator: "\n")
      exclusionsText = value.liveDebugExclusions.joined(separator: "\n")
    }

    private func saveDraft() {
      guard var value = draft else { return }
      value.arguments = ShellArgumentParser.parse(argumentsText)
      value.environment = parseEnvironment(environmentText)
      value.liveDebugWatchRoots = lines(watchRootsText)
      value.liveDebugExclusions = lines(exclusionsText)
      controller.update(value)
      select(value)
    }

    private func parseEnvironment(_ text: String) -> [String: String] {
      var values: [String: String] = [:]
      for line in lines(text) {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = parts.first.map(String.init), !key.isEmpty else { continue }
        values[key] = parts.count > 1 ? String(parts[1]) : ""
      }
      return values
    }

    private func lines(_ text: String) -> [String] {
      text.split(whereSeparator: \Character.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func shellQuote(_ value: String) -> String {
      guard !value.isEmpty else { return "''" }
      let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/@%+=:,"))
      if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
      return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func draftBinding<Value>(
      _ keyPath: WritableKeyPath<EditorRunConfiguration, Value>,
      fallback: Value
    ) -> Binding<Value> {
      Binding(
        get: { draft?[keyPath: keyPath] ?? fallback },
        set: { value in draft?[keyPath: keyPath] = value }
      )
    }

    private func optionalDraftBinding(
      _ keyPath: WritableKeyPath<EditorRunConfiguration, String?>
    ) -> Binding<String> {
      Binding(
        get: { draft?[keyPath: keyPath] ?? "" },
        set: { value in draft?[keyPath: keyPath] = value.isEmpty ? nil : value }
      )
    }

    private func arrayDraftBinding(
      _ keyPath: WritableKeyPath<EditorRunConfiguration, [String]>
    ) -> Binding<String> {
      Binding(
        get: { draft?[keyPath: keyPath].joined(separator: ", ") ?? "" },
        set: { value in
          draft?[keyPath: keyPath] = value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }.filter { !$0.isEmpty }
        }
      )
    }
  }
#endif
