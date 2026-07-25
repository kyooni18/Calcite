import AppKit
import SwiftUI

private enum EditorWorkspaceTransition {
  case open(workspace: URL, initialFile: URL?)
  case close
}

struct ContentView: View {
  @State private var workspaceURL: URL?
  @State private var initialFileURL: URL?
  @State private var documentOpenRequestID: UUID?
  @State private var activeController: EditorWorkspaceController?
  @State private var pendingTransition: EditorWorkspaceTransition?
  @State private var showsTransitionConfirmation = false
  @State private var projectSelectionError: String?
  @State private var isProjectPanelOpen = false
  @State private var isCreatingProject = false
  @Binding private var interfaceScale: Double
  @EnvironmentObject private var recents: EditorRecentItemsStore

  init(workspaceURL: URL? = nil, interfaceScale: Binding<Double> = .constant(1.0)) {
    _workspaceURL = State(
      initialValue: workspaceURL?.standardizedFileURL ?? EditorWorkspaceSelectionStore.load()
    )
    _interfaceScale = interfaceScale
  }

  var body: some View {
    Group {
      if let workspaceURL {
        CalciteWorkspaceHostView(
          workspaceURL: workspaceURL,
          initialFileURL: initialFileURL,
          documentOpenRequestID: documentOpenRequestID,
          recentItems: recents,
          onOpenItem: presentItemPicker,
          onControllerReady: { controller in activeController = controller }
        )
        .id(workspaceURL.path)
      } else {
        ProjectWelcomeView(
          newProject: { isCreatingProject = true },
          openProject: presentProjectPicker,
          openItem: presentItemPicker
        )
      }
    }
    .dynamicTypeSize(dynamicTypeSize)
    .controlSize(controlSize)
    .focusedSceneValue(
      \.appCommandHandler,
      AppCommandHandler(perform: performAppCommand)
    )
    .onOpenURL(perform: open)
    .confirmationDialog(
      "Save changes before switching projects?",
      isPresented: $showsTransitionConfirmation,
      titleVisibility: .visible
    ) {
      Button("Save and Continue") { completePendingTransition(saveChanges: true) }
      Button("Discard Changes", role: .destructive) {
        completePendingTransition(saveChanges: false)
      }
      Button("Cancel", role: .cancel) { pendingTransition = nil }
    } message: {
      Text("One or more open files have unsaved changes.")
    }
    .alert("Unable to Open Project", isPresented: projectSelectionErrorBinding) {
      Button("OK") { projectSelectionError = nil }
    } message: {
      Text(projectSelectionError ?? "The selected project could not be opened.")
    }
    .sheet(isPresented: $isCreatingProject) {
      NewProjectSheet { url in
        recents.add(url)
        requestTransition(.open(workspace: url, initialFile: nil))
      }
    }
  }

  private func performAppCommand(_ command: AppCommand) {
    switch command {
    case .newProject:
      isCreatingProject = true
    case .openProject:
      presentProjectPicker()
    case .openItem:
      presentItemPicker()
    case .openRecent(let url):
      open(url)
    case .closeProject:
      requestTransition(.close)
    }
  }

  private var dynamicTypeSize: DynamicTypeSize {
    switch interfaceScale {
    case ..<0.95: .small
    case ..<1.05: .medium
    case ..<1.15: .large
    case ..<1.25: .xLarge
    case ..<1.35: .xxLarge
    case ..<1.45: .xxxLarge
    case ..<1.55: .accessibility1
    case ..<1.65: .accessibility2
    case ..<1.75: .accessibility3
    case ..<1.85: .accessibility4
    default: .accessibility5
    }
  }

  private var controlSize: ControlSize {
    switch interfaceScale {
    case ..<0.95: .mini
    case ..<1.15: .small
    case ..<1.45: .regular
    default: .large
    }
  }

  private func open(_ suppliedURL: URL) {
    let url = suppliedURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return
    }

    if isDirectory.boolValue {
      if let validationError = EditorWorkspaceSelectionStore.validationError(for: url) {
        projectSelectionError = validationError
        return
      }
      recents.add(url)
      requestTransition(.open(workspace: url, initialFile: nil))
      return
    }

    let parent = url.deletingLastPathComponent().standardizedFileURL
    recents.add(url)
    EditorWorkspaceSelectionStore.save(parent)
    if workspaceURL?.standardizedFileURL == parent {
      initialFileURL = url
      documentOpenRequestID = UUID()
    } else {
      requestTransition(.open(workspace: parent, initialFile: url))
    }
  }

  private func requestTransition(_ transition: EditorWorkspaceTransition) {
    if activeController?.hasUnsavedDocuments == true {
      pendingTransition = transition
      showsTransitionConfirmation = true
    } else {
      performTransition(transition, saveChanges: true)
    }
  }

  private func completePendingTransition(saveChanges: Bool) {
    guard let transition = pendingTransition else { return }
    pendingTransition = nil
    performTransition(transition, saveChanges: saveChanges)
  }

  private func performTransition(_ transition: EditorWorkspaceTransition, saveChanges: Bool) {
    Task { @MainActor in
      if let activeController,
        !(await activeController.shutdown(saveChanges: saveChanges))
      {
        projectSelectionError =
          "One or more documents could not be saved. The current project remains open."
        return
      }
      self.activeController = nil
      switch transition {
      case .open(let workspace, let initialFile):
        let workspace = workspace.standardizedFileURL
        EditorWorkspaceSelectionStore.save(workspace)
        initialFileURL = initialFile?.standardizedFileURL
        documentOpenRequestID = initialFile == nil ? nil : UUID()
        workspaceURL = workspace
      case .close:
        EditorWorkspaceSelectionStore.clear()
        initialFileURL = nil
        documentOpenRequestID = nil
        workspaceURL = nil
      }
    }
  }

  private var projectSelectionErrorBinding: Binding<Bool> {
    Binding(
      get: { projectSelectionError != nil },
      set: { if !$0 { projectSelectionError = nil } }
    )
  }

  private func presentProjectPicker() {
    guard !isProjectPanelOpen else { return }
    isProjectPanelOpen = true

    let panel = NSOpenPanel()
    panel.title = "Open Project"
    panel.message = "Choose the project folder."
    panel.prompt = "Open Project"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.directoryURL = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser

    panel.begin { response in
      Task { @MainActor in
        isProjectPanelOpen = false
        guard response == .OK, let selected = panel.url?.standardizedFileURL else { return }
        if let validationError = EditorWorkspaceSelectionStore.validationError(for: selected) {
          projectSelectionError = validationError
          return
        }
        recents.add(selected)
        requestTransition(.open(workspace: selected, initialFile: nil))
      }
    }
  }

  private func presentItemPicker() {
    guard !isProjectPanelOpen else { return }
    isProjectPanelOpen = true
    let panel = NSOpenPanel()
    panel.title = "Open File or Folder"
    panel.prompt = "Open"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.directoryURL = workspaceURL
    panel.begin { response in
      Task { @MainActor in
        isProjectPanelOpen = false
        if response == .OK, let url = panel.url { open(url) }
      }
    }
  }
}

private struct ProjectWelcomeView: View {
  let newProject: () -> Void
  let openProject: () -> Void
  let openItem: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Open a Project", systemImage: "folder.badge.plus")
    } description: {
      Text("Choose a project folder to begin.")
    } actions: {
      Button("New Project…", action: newProject)
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Open Project…", action: openProject)
        .keyboardShortcut("o", modifiers: .command)
      Button("Open File…", action: openItem)
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
  }
}

private struct NewProjectSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var language: ProjectLanguage = .swift
  @State private var location = FileManager.default.homeDirectoryForCurrentUser
  @State private var error: String?

  let didCreate: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("New Project")
        .font(.title2.weight(.semibold))

      Form {
        TextField("Project Name", text: $name)
          .textFieldStyle(.roundedBorder)
        Picker("Language", selection: $language) {
          ForEach(ProjectLanguage.allCases) { language in
            Text("\(language.rawValue) — \(language.detail)").tag(language)
          }
        }
        HStack {
          Text("Location")
          Text(location.path)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Choose…", action: chooseLocation)
        }
      }

      if let error {
        Text(error)
          .foregroundStyle(.red)
          .font(.callout)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 560)
  }

  private func chooseLocation() {
    let panel = NSOpenPanel()
    panel.title = "Choose Project Location"
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = location
    panel.begin { response in
      guard response == .OK, let url = panel.url?.standardizedFileURL else { return }
      location = url
    }
  }

  private func create() {
    do {
      let projectURL = try ProjectTemplate.create(named: name, language: language, in: location)
      didCreate(projectURL)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

#Preview {
  ContentView(workspaceURL: FileManager.default.temporaryDirectory)
}
