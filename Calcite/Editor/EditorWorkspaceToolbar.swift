import AppKit
import EditorServices
import SwiftUI

struct EditorTabsBar: View {
  let tabs: [EditorTab]
  @Binding var selectedID: EditorTab.ID?
  let close: (EditorTab) -> Void
  let save: (EditorTab) -> Void
  let openToSide: (EditorTab) -> Void
  let splitRight: () -> Void
  let splitBelow: () -> Void
  let closeSplit: (() -> Void)?

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: 0) {
          ForEach(tabs) { tab in
            HStack(spacing: 0) {
              Button {
                selectedID = tab.id
              } label: {
                EditorTabLabel(tab: tab, isSelected: selectedID == tab.id)
              }
              .buttonStyle(.plain)

              Button {
                close(tab)
              } label: {
                Image(systemName: "xmark")
                  .font(.system(size: 9, weight: .semibold))
                  .padding(6)
              }
              .buttonStyle(.plain)
              .help("Close \(tab.title)")
            }
            .background {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selectedID == tab.id ? Color.accentColor.opacity(0.14) : .clear)
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
            .contextMenu {
              Button {
                selectedID = tab.id
                save(tab)
              } label: {
                Label("Save", systemImage: "square.and.arrow.down")
              }
              .disabled(!tab.isDirty)

              Button {
                openToSide(tab)
              } label: {
                Label("Open to Side", systemImage: "rectangle.split.2x1")
              }

              Divider()

              Button {
                NSWorkspace.shared.activateFileViewerSelecting([tab.url])
              } label: {
                Label("Reveal in Finder", systemImage: "folder")
              }

              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url.path, forType: .string)
              } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
              }

              Divider()

              Button(role: .destructive) {
                selectedID = tab.id
                close(tab)
              } label: {
                Label("Close Tab", systemImage: "xmark")
              }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
            Divider()
          }
        }
      }
      .scrollIndicators(.hidden)
      .frame(maxWidth: .infinity)

      Menu {
        Button("Split Right", systemImage: "rectangle.split.2x1", action: splitRight)
        Button("Split Below", systemImage: "rectangle.split.1x2", action: splitBelow)
        if let closeSplit {
          Divider()
          Button("Close Split", systemImage: "rectangle") { closeSplit() }
        }
      } label: {
        Image(systemName: "rectangle.split.2x1")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 26, height: 26)
      }
      .menuStyle(.borderlessButton)
      .help("Editor layout")
      .padding(.trailing, 4)
    }
    .frame(height: 30)
    .background(.bar)
    .animation(.snappy(duration: 0.22, extraBounce: 0.08), value: tabs.map(\.id))
    .animation(.easeInOut(duration: 0.16), value: selectedID)
  }
}

struct ProblemToolbarControl: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject private var buildController: EditorBuildController
  let isSelected: Bool
  let action: () -> Void

  init(
    controller: EditorWorkspaceController,
    isSelected: Bool,
    action: @escaping () -> Void
  ) {
    self.controller = controller
    _buildController = ObservedObject(wrappedValue: controller.buildController)
    self.isSelected = isSelected
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(
          systemName: isSelected
            ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
        )
        if problemCount > 0 {
          Text(problemCount.formatted())
            .font(.caption2.monospacedDigit())
        }
      }
      .frame(width: 42)
    }
    .accessibilityLabel(problemCount > 0 ? "Errors, \(problemCount)" : "Errors")
    .help(problemCount > 0 ? "Errors (\(problemCount))" : "Errors")
    .transaction { $0.animation = nil }
  }

  private var problemCount: Int {
    controller.tabs.reduce(0) { $0 + $1.diagnostics.count }
      + buildController.diagnostics.count
  }
}

struct BuildToolbarControls: View {
  @ObservedObject var controller: EditorWorkspaceController
  @ObservedObject private var buildController: EditorBuildController
  let run: (EditorBuildCommand) -> Void
  let cancel: () -> Void

  init(
    controller: EditorWorkspaceController,
    run: @escaping (EditorBuildCommand) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.controller = controller
    _buildController = ObservedObject(wrappedValue: controller.buildController)
    self.run = run
    self.cancel = cancel
  }

  var body: some View {
    ControlGroup {
      Button(action: performPrimaryAction) {
        Image(systemName: primaryActionSymbol)
          .frame(width: 16, height: 16)
      }
      .accessibilityLabel(primaryActionTitle)
      .help(primaryActionTitle)
      .disabled(!hasActiveTask && preferredCommand == nil)

      Menu {
        if buildController.plan.commands.isEmpty {
          Text("No tasks detected")
        } else {
          ForEach(buildController.plan.commands) { command in
            Button {
              run(command)
            } label: {
              Label(command.title, systemImage: taskSymbol(command))
            }
          }
        }
      } label: {
        Image(systemName: "chevron.down")
          .frame(width: 12, height: 16)
      }
      .accessibilityLabel("Choose Task")
      .help("Choose Build Task")
      .disabled(hasActiveTask)
    }
    .controlSize(.small)
    .frame(width: 62)
    .transaction { transaction in
      transaction.animation = nil
    }
  }

  private var hasActiveTask: Bool {
    controller.isPreparingBuildTask || buildController.phase.isRunning
  }

  private var primaryActionTitle: String {
    hasActiveTask ? activeTaskDescription : (preferredCommand?.title ?? "Run Task")
  }

  private var primaryActionSymbol: String {
    hasActiveTask ? "stop.fill" : "play.fill"
  }

  private func performPrimaryAction() {
    if hasActiveTask {
      cancel()
    } else if let preferredCommand {
      run(preferredCommand)
    }
  }

  private var preferredCommand: EditorBuildCommand? {
    buildController.selectedCommand
      ?? buildController.plan.command(for: .run)
      ?? buildController.plan.command(for: .build)
      ?? buildController.plan.commands.first
  }

  private var activeTaskDescription: String {
    if controller.isPreparingBuildTask { return "Saving files before launching the task" }
    switch buildController.phase {
    case .running(let title): return "Cancel \(title)"
    case .cancelling(let title): return "Cancelling \(title)"
    case .idle, .cancelled, .succeeded, .failed: return "Cancel task"
    }
  }

  private func taskSymbol(_ command: EditorBuildCommand) -> String {
    switch command.kind {
    case .build: return "hammer"
    case .run: return "play.fill"
    case .test: return "checkmark.seal"
    case .check: return "checkmark.circle"
    case .clean: return "trash"
    case .custom: return "terminal"
    }
  }
}
