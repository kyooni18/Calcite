import Combine
internal import EditorWorkspace
import SwiftUI

/// Backend-driven workspace composition used by every project window.
@MainActor
struct CalciteWorkspaceView: View {
  @Environment(\.colorScheme) private var colorScheme

  @StateObject private var context: CalciteWorkspaceContext

  private var backend: CalciteBackend { context.backend }
  private var windowSession: CalciteBackendWindowSession { context.windowSession }

  let initialFileURL: URL?
  let documentOpenRequestID: UUID?
  let onControllerReady: (EditorWorkspaceController?) -> Void

  @State private var pendingDocumentOpenURL: URL?
  @State private var didBeginClose = false
  @FocusState private var topSearchIsFocused: Bool

  init(
    backend: CalciteBackend,
    windowSession: CalciteBackendWindowSession,
    initialFileURL: URL? = nil,
    documentOpenRequestID: UUID? = nil,
    onControllerReady: @escaping (EditorWorkspaceController?) -> Void = { _ in }
  ) {
    _context = StateObject(
      wrappedValue: CalciteWorkspaceContext(
        backend: backend,
        windowSession: windowSession
      )
    )
    self.initialFileURL = initialFileURL
    self.documentOpenRequestID = documentOpenRequestID
    self.onControllerReady = onControllerReady
  }

  var body: some View {
    dialogView
  }

  private var configuredRootView: some View {
    presentationRootView
      .preferredColorScheme(windowSession.effectiveAppearanceMode.colorScheme)
      .foregroundStyle(backend.controller.profile.workbench.foreground.color)
      .tint(backend.controller.profile.workbench.accent.color)
  }

  private var presentationRootView: some View {
    workbenchView
      .background(backend.controller.profile.workbench.windowBackground.color)
      .background(
        EditorWindowAppearanceApplier(
          mode: windowSession.effectiveAppearanceMode,
          backgroundColor: backend.controller.profile.workbench.windowBackground.nsColor
        )
      )
      .background(EditorWindowLayoutPersistence(workspaceURL: backend.workspaceURL))
      .background(EditorInitialFocusGuard())
      .focusedSceneValue(
        \.editorCommandHandler,
        EditorCommandHandler(perform: { command in windowSession.perform(command) })
      )
      .focusedSceneValue(\.editorCommandAvailability, windowSession.commandAvailability)
      .task {
        windowSession.markActive()
        backend.activateTheme(for: colorScheme)
        let state = await windowSession.start(initialFileURL: initialFileURL)
        switch state {
        case .running, .failed:
          onControllerReady(backend.controller)
        case .idle, .starting, .stopping, .stopped:
          onControllerReady(nil)
        }

        if state == .running, let pendingDocumentOpenURL {
          _ = await windowSession.openDocument(at: pendingDocumentOpenURL)
          self.pendingDocumentOpenURL = nil
        }
      }
      .onAppear {
        windowSession.markActive()
      }
      .onDisappear {
        closeWindowSessionIfNeeded()
      }
      .onChange(of: themeActivationKey) { _, _ in
        backend.activateTheme(for: colorScheme)
      }
      .onChange(of: windowSession.palette.focusRequestID) { _, _ in
        topSearchIsFocused = true
      }
      .onChange(of: backend.documents.map(\.id)) { _, _ in
        windowSession.reconcileDocuments()
      }
      .onChange(of: backend.activeDocumentID) { _, documentID in
        guard backend.activeWindowSession === windowSession else { return }
        windowSession.synchronizeSelectedDocumentFromController(documentID)
      }
      .onChange(of: documentOpenRequestID) { _, requestID in
        guard requestID != nil, let initialFileURL else { return }
        if backend.lifecycleState == .running {
          Task { @MainActor in
            _ = await windowSession.openDocument(at: initialFileURL)
          }
        } else {
          pendingDocumentOpenURL = initialFileURL
        }
      }
  }

  private var workbenchView: some View {
    CalciteWorkbenchRootView {
      CalciteWorkspaceHeader(
        backend: backend,
        windowSession: windowSession,
        searchFocus: $topSearchIsFocused
      )
    } content: {
      MainSectionalView(
        backend: backend,
        windowSession: windowSession
      )
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .clipped()
    }
  }

  private var dialogView: some View {
    presentationView
      .confirmationDialog(
        "File Changed on Disk",
        isPresented: externalFileConflictBinding,
        titleVisibility: .visible
      ) {
        Button("Keep Editor") {
          backend.resolveExternalFileConflict(using: .useMemory)
        }
        Button("Use Disk", role: .destructive) {
          backend.resolveExternalFileConflict(using: .useDisk)
        }
        Button("Later", role: .cancel) {
          backend.dismissExternalFileConflict()
        }
      } message: {
        Text(
          (backend.controller.externalFileConflict?.message ?? "File changed on disk.")
            + " Keep Editor overwrites disk. Use Disk discards local edits."
        )
      }
      .alert("File Operation Failed", isPresented: fileOperationErrorBinding) {
        Button("OK") { backend.controller.fileOperationError = nil }
      } message: {
        Text(backend.controller.fileOperationError ?? "The file operation failed.")
      }
      .alert("Recovery Limited", isPresented: recoveryWarningBinding) {
        Button("OK") { backend.controller.recoveryWarning = nil }
      } message: {
        Text(
          backend.controller.recoveryWarning
            ?? "Some files could not be included in crash recovery."
        )
      }
      .confirmationDialog(
        "Close modified file?",
        isPresented: documentCloseDialogBinding,
        titleVisibility: .visible
      ) {
        Button("Save and Close") {
          resolveDocumentClose(.save)
        }
        Button("Discard Changes", role: .destructive) {
          resolveDocumentClose(.discard)
        }
        Button("Cancel", role: .cancel) {
          resolveDocumentClose(.cancel)
        }
      } message: {
        Text(windowSession.pendingDocumentClose?.title ?? "")
      }
  }

  private var presentationView: some View {
    configuredRootView
      .overlay(alignment: .top) {
        if windowSession.palette.isPresented {
          ZStack(alignment: .top) {
            Color.black.opacity(0.001)
              .contentShape(Rectangle())
              .padding(.top, 33)
              .onTapGesture {
                closeCommandPalette()
              }

            CalciteCommandPalette(
              backend: backend,
              windowSession: windowSession,
              showsSearchHeader: false
            )
            .frame(width: 640, height: 430)
            .background(
              backend.controller.profile.workbench.panelBackground.color,
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                  backend.controller.profile.workbench.border.color.opacity(0.8),
                  lineWidth: 1
                )
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
      .animation(.easeOut(duration: 0.14), value: windowSession.palette.isPresented)
      .overlay(alignment: .bottomTrailing) {
        CalciteStatusOverlay(backend: backend)
          .padding(10)
          .zIndex(90)
      }
      .popover(
        item: binding(
          get: { backend.controller.symbolInformation },
          set: { backend.controller.symbolInformation = $0 }
        ),
        attachmentAnchor: .rect(.bounds),
        arrowEdge: .bottom
      ) { information in
        CalciteSymbolInformationPopover(information: information)
      }
      .sheet(
        item: binding(
          get: { backend.controller.symbolLocations },
          set: { backend.controller.symbolLocations = $0 }
        )
      ) { collection in
        CalciteSymbolLocationsSheet(
          backend: backend,
          collection: collection
        )
      }
  }

  private var themeActivationKey: CalciteThemeActivationKey {
    CalciteThemeActivationKey(
      systemScheme: colorScheme,
      appearanceModeRaw: windowSession.appearanceModeRaw,
      forcedAppearanceRaw: backend.controller.profile.forcedInterfaceAppearance?.rawValue
    )
  }

  private var externalFileConflictBinding: Binding<Bool> {
    binding(
      get: { backend.controller.externalFileConflict != nil },
      set: { isPresented in
        if !isPresented {
          backend.dismissExternalFileConflict()
        }
      }
    )
  }

  private var fileOperationErrorBinding: Binding<Bool> {
    binding(
      get: { backend.controller.fileOperationError != nil },
      set: { isPresented in
        if !isPresented {
          backend.controller.fileOperationError = nil
        }
      }
    )
  }

  private var recoveryWarningBinding: Binding<Bool> {
    binding(
      get: { backend.controller.recoveryWarning != nil },
      set: { isPresented in
        if !isPresented {
          backend.controller.recoveryWarning = nil
        }
      }
    )
  }

  private var documentCloseDialogBinding: Binding<Bool> {
    binding(
      get: { windowSession.pendingDocumentClose != nil },
      set: { isPresented in
        if !isPresented, windowSession.pendingDocumentClose != nil {
          resolveDocumentClose(.cancel)
        }
      }
    )
  }

  private func resolveDocumentClose(
    _ decision: CalciteBackendWindowSession.DocumentCloseDecision
  ) {
    Task { @MainActor in
      _ = await windowSession.resolvePendingDocumentClose(decision)
    }
  }

  private func closeCommandPalette() {
    withAnimation(.easeOut(duration: 0.12)) {
      windowSession.closeCommandPalette()
    }
    topSearchIsFocused = false
  }

  private func closeWindowSessionIfNeeded() {
    guard !didBeginClose else { return }
    didBeginClose = true
    windowSession.stopNowPlaying()

    Task { @MainActor in
      let closed = await windowSession.close()
      if closed {
        onControllerReady(nil)
      } else {
        didBeginClose = false
      }
    }
  }

  private func binding<Value>(
    get: @escaping @MainActor @Sendable () -> Value,
    set: @escaping @MainActor @Sendable (Value) -> Void
  ) -> Binding<Value> {
    Binding(get: get, set: set)
  }
}

@MainActor
private final class CalciteWorkspaceContext: ObservableObject {
  let backend: CalciteBackend
  let windowSession: CalciteBackendWindowSession

  private var observations = Set<AnyCancellable>()
  private var invalidationScheduled = false

  init(
    backend: CalciteBackend,
    windowSession: CalciteBackendWindowSession
  ) {
    precondition(
      windowSession.backend === backend,
      "The window session must belong to the supplied CalciteBackend."
    )
    self.backend = backend
    self.windowSession = windowSession
    observeChanges()
  }

  private func observeChanges() {
    backend.objectWillChange
      .sink { [weak self] _ in self?.scheduleInvalidation() }
      .store(in: &observations)
    windowSession.objectWillChange
      .sink { [weak self] _ in self?.scheduleInvalidation() }
      .store(in: &observations)
  }

  /// Coalesce child-object changes outside SwiftUI's current view update.
  private func scheduleInvalidation() {
    guard !invalidationScheduled else { return }
    invalidationScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.invalidationScheduled = false
      self.objectWillChange.send()
    }
  }
}

nonisolated private struct CalciteThemeActivationKey: Equatable {
  let systemScheme: ColorScheme
  let appearanceModeRaw: String
  let forcedAppearanceRaw: String?
}
