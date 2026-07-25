import SwiftUI

struct CalciteStatusIndicator: View {
  @ObservedObject var store: CalciteLogStore
  let phase: EditorWorkspacePhase
  @State private var showsDetails = false

  private var recentIssue: CalciteLogEntry? {
    store.entries.last { $0.level >= .warning }
  }

  var body: some View {
    Button {
      showsDetails.toggle()
    } label: {
      HStack(spacing: 6) {
        if !store.activeOperations.isEmpty || phase == .starting {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: recentIssue?.level.systemImage ?? "checkmark.circle")
            .font(.caption)
            .foregroundStyle(
              recentIssue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        Text(statusTitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(.thinMaterial, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Show advanced status")
    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
      AdvancedStatusView(store: store, phase: phase)
    }
  }

  private var statusTitle: String {
    if let operation = store.activeOperations.last { return operation.title }
    switch phase {
    case .idle: return "Idle"
    case .starting: return "Starting"
    case .ready: return recentIssue == nil ? "Ready" : "Review log"
    case .failed: return "Failed"
    }
  }
}

private struct AdvancedStatusView: View {
  @ObservedObject var store: CalciteLogStore
  let phase: EditorWorkspacePhase

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Advanced Status").font(.headline)
        Spacer()
        Button("Copy", systemImage: "doc.on.doc") { store.copyVisibleHistory() }
          .labelStyle(.iconOnly)
          .help("Copy visible logs")
        Button("Reveal Log", systemImage: "folder") { store.revealLogFile() }
          .labelStyle(.iconOnly)
          .help("Reveal persistent log file")
        Button("Clear", systemImage: "trash") { store.clearVisibleHistory() }
          .labelStyle(.iconOnly)
          .help("Clear visible history")
      }

      if !store.activeOperations.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("ACTIVE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(store.activeOperations) { operation in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                ProgressView().controlSize(.mini)
                Text(operation.title).font(.callout.weight(.medium))
                Spacer()
                Text(operation.startedAt, style: .timer).font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              if let detail = operation.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
              if let progress = operation.progress {
                ProgressView(value: progress).controlSize(.small)
              }
            }
          }
        }
      }

      Divider()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if store.entries.isEmpty {
            Text("No log entries.").foregroundStyle(.secondary).frame(
              maxWidth: .infinity, alignment: .center)
          } else {
            ForEach(store.entries.suffix(80).reversed()) { entry in
              HStack(alignment: .top, spacing: 7) {
                Image(systemName: entry.level.systemImage)
                  .foregroundStyle(
                    entry.level >= .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                  )
                  .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 6) {
                    Text(entry.category).font(.caption.weight(.medium))
                    Text(entry.timestamp, style: .time).font(.caption2.monospacedDigit())
                      .foregroundStyle(.tertiary)
                  }
                  Text(entry.message).font(.caption).textSelection(.enabled)
                  if !entry.metadata.isEmpty {
                    Text(
                      entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                        .joined(separator: "  ·  ")
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                  }
                }
                Spacer(minLength: 0)
              }
            }
          }
        }
      }
      .frame(height: 270)
    }
    .padding(14)
    .frame(width: 470)
  }
}
