import SwiftUI

#if os(macOS)
  struct CalciteBreakpointListView: View {
    @ObservedObject var coordinator: EditorBreakpointCoordinator
    let workspaceURL: URL
    let update: (EditorStoredBreakpoint) -> Void
    let remove: (EditorStoredBreakpoint) -> Void

    @State private var editingRecord: EditorStoredBreakpoint?

    var body: some View {
      VStack(spacing: 0) {
        HStack {
          Label("Breakpoints", systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
          Spacer()
          Text("\(coordinator.records.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar.opacity(0.75))

        List(coordinator.records) { record in
          breakpointRow(record)
        }
        .overlay {
          if coordinator.records.isEmpty {
            ContentUnavailableView(
              "No Breakpoints",
              systemImage: "circle.dashed",
              description: Text("Click a line number or use Toggle Breakpoint.")
            )
          }
        }
      }
      .sheet(item: $editingRecord) { record in
        BreakpointEditorSheet(record: record) { value in
          update(value)
          editingRecord = nil
        } remove: { value in
          remove(value)
          editingRecord = nil
        }
      }
    }

    private func breakpointRow(_ record: EditorStoredBreakpoint) -> some View {
      HStack(spacing: 7) {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { record.isEnabled },
            set: { enabled in
              var value = record
              value.isEnabled = enabled
              update(value)
            }
          )
        )
        .labelsHidden()
        .toggleStyle(.checkbox)

        Button {
          editingRecord = record
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
              Text(record.documentURL?.lastPathComponent ?? "Unknown file")
                .font(.caption.weight(.medium))
              Text(":\(record.effectiveLine)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              if record.resolvedLine != nil, record.resolvedLine != record.requestedLine {
                Text("from \(record.requestedLine)")
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.orange)
              }
            }
            HStack(spacing: 6) {
              if record.condition?.isEmpty == false {
                Label("Condition", systemImage: "function")
              }
              if record.hitCondition?.isEmpty == false {
                Label("Hit", systemImage: "number")
              }
              if record.logMessage?.isEmpty == false {
                Label("Log", systemImage: "text.bubble")
              }
              if let message = record.verificationMessage, !message.isEmpty {
                Text(message).lineLimit(1)
              } else {
                Text(relativePath(record.documentURL)).lineLimit(1)
              }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }

    private func relativePath(_ url: URL?) -> String {
      guard let url else { return "Unknown path" }
      let root = workspaceURL.standardizedFileURL.path
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(root) else { return path }
      return String(path.dropFirst(root.count)).trimmingCharacters(
        in: CharacterSet(charactersIn: "/")
      )
    }
  }

  private struct BreakpointEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var record: EditorStoredBreakpoint
    let save: (EditorStoredBreakpoint) -> Void
    let remove: (EditorStoredBreakpoint) -> Void

    init(
      record: EditorStoredBreakpoint,
      save: @escaping (EditorStoredBreakpoint) -> Void,
      remove: @escaping (EditorStoredBreakpoint) -> Void
    ) {
      _record = State(initialValue: record)
      self.save = save
      self.remove = remove
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(record.documentURL?.lastPathComponent ?? "Breakpoint")
              .font(.title3.weight(.semibold))
            Text("Requested line \(record.requestedLine) · resolved line \(record.effectiveLine)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Enabled", isOn: $record.isEnabled)
        }

        Form {
          TextField(
            "Condition",
            text: optionalBinding(\.condition),
            prompt: Text("example: count > 4")
          )
          TextField(
            "Hit Condition",
            text: optionalBinding(\.hitCondition),
            prompt: Text("example: 10 or >= 10")
          )
          TextField(
            "Log Message",
            text: optionalBinding(\.logMessage),
            prompt: Text("Print without stopping; adapters may support {expression}")
          )
        }
        .formStyle(.grouped)

        if let verification = record.verificationMessage, !verification.isEmpty {
          Label(verification, systemImage: "scope")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Button("Delete", role: .destructive) { remove(record) }
          Spacer()
          Button("Cancel") { dismiss() }
          Button("Save") { save(record) }
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(18)
      .frame(width: 500)
    }

    private func optionalBinding(
      _ keyPath: WritableKeyPath<EditorStoredBreakpoint, String?>
    ) -> Binding<String> {
      Binding(
        get: { record[keyPath: keyPath] ?? "" },
        set: { value in record[keyPath: keyPath] = value.isEmpty ? nil : value }
      )
    }
  }
#endif
