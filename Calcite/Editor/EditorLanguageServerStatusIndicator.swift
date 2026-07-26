import EditorServices
import SwiftUI

struct EditorLanguageServerStatusIndicator: View {
  let languageID: String?
  let workspacePhase: EditorWorkspacePhase
  let report: EditorServiceAvailabilityReport
    let backend: CalciteBackend

  @State private var showsDetails = false

  private enum State {
    case inactive
    case starting
    case ready(EditorServiceDiagnostic)
    case unavailable(EditorServiceDiagnostic?)
    case failed(String)
  }

  var body: some View {
    Button {
      showsDetails.toggle()
    } label: {
      HStack(spacing: 5) {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
        Text(compactTitle)
          .font(.caption2)
          .lineLimit(1)
      }
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(helpText)
    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
      details
        .frame(width: 300)
        .padding(12)
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(detailTitle).font(.headline)
        Spacer()
        CalciteStatusOverlay(backend: backend)
      }
      Divider()
      switch state {
      case .ready(let diagnostic):
        detailRow("Service", diagnostic.serviceName)
        if case .available(let path) = diagnostic.availability, let path, !path.isEmpty {
          detailRow("Executable", path)
        }
      case .unavailable(let diagnostic):
        if let diagnostic {
          detailRow("Service", diagnostic.serviceName)
          if let suggestion = diagnostic.recoverySuggestion, !suggestion.isEmpty {
            Text(suggestion).font(.caption).foregroundStyle(.secondary)
          }
          if !diagnostic.attemptedLocations.isEmpty {
            Text("Checked \(diagnostic.attemptedLocations.count) locations")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        } else {
          Text("No language server is configured for the active document.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      case .failed(let message):
        Text(message).font(.caption).foregroundStyle(.secondary)
      case .starting:
        Text("The workspace and language services are initializing.")
          .font(.caption)
          .foregroundStyle(.secondary)
      case .inactive:
        Text("Open a source file to inspect its language server.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
      Text(value).font(.caption).textSelection(.enabled).lineLimit(2)
    }
  }

  private var state: State {
    switch workspacePhase {
    case .idle:
      return .inactive
    case .starting:
      return .starting
    case .failed(let message):
      return .failed(message)
    case .ready:
      guard let language else { return .inactive }
      let diagnostics = report.diagnostics(for: language, feature: .languageServer)
      if let available = diagnostics.first(where: { $0.availability.isAvailable }) {
        return .ready(available)
      }
      return .unavailable(diagnostics.first)
    }
  }

  private var language: EditorLanguage? {
    guard let languageID else { return nil }
    let normalized = languageID.lowercased()
    let aliases: [String: String] = [
      "c++": "cpp", "objc": "objective-c", "objectivec": "objective-c",
      "objcpp": "objective-cpp", "objectivecpp": "objective-cpp",
      "js": "javascript", "jsx": "javascript", "ts": "typescript",
      "tsx": "typescript", "sh": "shellscript", "bash": "shellscript",
      "zsh": "shellscript", "md": "markdown",
    ]
    return EditorLanguage(rawValue: aliases[normalized] ?? normalized)
  }

  private var statusColor: Color {
    switch state {
    case .ready: .green
    case .starting: .yellow
    case .failed, .unavailable: .red
    case .inactive: .secondary
    }
  }

  private var compactTitle: String {
    switch state {
    case .ready(let diagnostic): diagnostic.serviceName
    case .starting: "Language Server"
    case .failed: "LSP Failed"
    case .unavailable(let diagnostic): diagnostic?.serviceName ?? "No LSP"
    case .inactive: "LSP"
    }
  }

  private var detailTitle: String {
    language?.rawValue ?? "Language Server"
  }

  private var statusLabel: String {
    switch state {
    case .ready: "Ready"
    case .starting: "Starting"
    case .failed: "Failed"
    case .unavailable: "Unavailable"
    case .inactive: "Inactive"
    }
  }

  private var helpText: String { "\(compactTitle): \(statusLabel)" }
}
