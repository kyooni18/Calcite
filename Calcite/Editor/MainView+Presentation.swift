import SwiftUI
internal import EditorWorkspace

extension MainView {
  var dialogView: some View {
    presentationView
      .confirmationDialog(
        "File Changed on Disk",
        isPresented: externalFileConflictBinding,
        titleVisibility: .visible
      ) {
        externalConflictActions
      } message: {
        externalConflictMessage
      }
      .alert("File Operation Failed", isPresented: fileOperationErrorBinding) {
        Button("OK") { controller.fileOperationError = nil }
      } message: {
        Text(controller.fileOperationError ?? "The file operation failed.")
      }
      .alert("Recovery Limited", isPresented: recoveryWarningBinding) {
        Button("OK") { controller.recoveryWarning = nil }
      } message: {
        Text(controller.recoveryWarning ?? "Some files could not be included in crash recovery.")
      }
      .confirmationDialog(
        "Close modified file?",
        isPresented: closeDialogBinding,
        titleVisibility: .visible
      ) {
        closeDialogActions
      } message: {
        Text(pendingClose?.title ?? "")
      }
      .confirmationDialog(
        "Close Theme Builder?",
        isPresented: utilityCloseDialogBinding,
        titleVisibility: .visible
      ) {
        utilityCloseDialogActions
      } message: {
        Text("The current theme has changes. Keep or revert them before closing the tab.")
      }
  }

  var presentationView: some View {
    configuredRootView
      .overlay(alignment: .top) {
        if palette.isPresented {
          ZStack(alignment: .top) {
            Color.black.opacity(0.001)
              .contentShape(Rectangle())
              .padding(.top, 33)
              .onTapGesture { closeCommandPalette() }

            EditorCommandPalette(
              workspaceURL: controller.workspaceURL,
              mode: palette.mode,
              actions: commandPaletteActions,
              openFile: commandExecutor.openDocument,
              dismiss: closeCommandPalette,
              query: $palette.query,
              includeIgnoredFiles: $fileVisibility.showsIgnoredFiles,
              includeBuildArtifacts: $fileVisibility.showsBuildArtifacts,
              includeHiddenFiles: $fileVisibility.showsHiddenFiles,
              includeDSStore: $fileVisibility.showsDSStore,
              showsSearchHeader: false,
              keyboardEvent: palette.keyboardEvent
            )
            .frame(width: 640, height: 430)
            .background(
              controller.profile.workbench.panelBackground.color,
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(controller.profile.workbench.border.color.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            .padding(.top, 34)
            .onTapGesture {}
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
          .zIndex(100)
        }
      }
      .animation(.easeOut(duration: 0.14), value: palette.isPresented)
      .overlay(alignment: .bottomTrailing) {
        CalciteStatusIndicator(store: CalciteLogStore.shared, phase: controller.phase)
          .padding(10)
          .zIndex(90)
      }
      .popover(
        item: $controller.symbolInformation,
        attachmentAnchor: .rect(.bounds),
        arrowEdge: .bottom
      ) { information in
        EditorSymbolInformationPopover(information: information)
      }
      .sheet(item: $controller.symbolLocations) { collection in
        EditorSymbolLocationsSheet(
          collection: collection,
          workspaceURL: controller.workspaceURL,
          open: controller.openSymbolLocation
        )
      }
  }

  var externalConflictMessage: some View {
    Text(
      (controller.externalFileConflict?.message ?? "File changed on disk.")
        + " Keep Editor overwrites disk. Use Disk discards local edits."
    )
  }

  @ViewBuilder
  var externalConflictActions: some View {
    Button("Keep Editor") {
      controller.resolveExternalFileConflict(using: .useMemory)
    }
    Button("Use Disk", role: .destructive) {
      controller.resolveExternalFileConflict(using: .useDisk)
    }
    Button("Later", role: .cancel) {
      controller.dismissExternalFileConflict()
    }
  }

  @ViewBuilder
  var closeDialogActions: some View {
    Button("Save and Close") {
      guard let tab = pendingClose else { return }
      controller.closeTab(tab, saving: true)
      pendingClose = nil
    }
    Button("Discard Changes", role: .destructive) {
      guard let tab = pendingClose else { return }
      controller.closeTab(tab)
      pendingClose = nil
    }
    Button("Cancel", role: .cancel) { pendingClose = nil }
  }

  @ViewBuilder
  var utilityCloseDialogActions: some View {
    Button("Keep Changes and Close") {
      themeBuilderSession.save()
      closePendingUtilityTab()
    }
    Button("Revert and Close", role: .destructive) {
      themeBuilderSession.discard()
      closePendingUtilityTab()
    }
    Button("Cancel", role: .cancel) {
      pendingUtilityClose = nil
    }
  }

  var externalFileConflictBinding: Binding<Bool> {
    Binding(
      get: { controller.externalFileConflict != nil },
      set: { if !$0 { controller.dismissExternalFileConflict() } }
    )
  }

  var fileOperationErrorBinding: Binding<Bool> {
    Binding(
      get: { controller.fileOperationError != nil },
      set: { if !$0 { controller.fileOperationError = nil } }
    )
  }

  var recoveryWarningBinding: Binding<Bool> {
    Binding(
      get: { controller.recoveryWarning != nil },
      set: { if !$0 { controller.recoveryWarning = nil } }
    )
  }

  var closeDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingClose != nil },
      set: { if !$0 { pendingClose = nil } }
    )
  }

  var utilityCloseDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingUtilityClose != nil },
      set: { if !$0 { pendingUtilityClose = nil } }
    )
  }
}
