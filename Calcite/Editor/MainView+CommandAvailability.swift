import EditorServices

extension EditorWorkspaceController {
  var commandAvailability: EditorCommandAvailability {
    let activeTab = activeTab
    let projectPlan = buildController.plan
    let activeFileURL = activeTab?.url
    let canBuild = EditorBuildTaskResolver.canExecute(
      projectPlan: projectPlan,
      activeFileURL: activeFileURL,
      kind: .build
    )
    let canRun = EditorBuildTaskResolver.canExecute(
      projectPlan: projectPlan,
      activeFileURL: activeFileURL,
      kind: .run
    )
    let isBuilding = isPreparingBuildTask || buildController.phase.isRunning

    let debugIsActive: Bool
    let debugIsRunning: Bool
    let debugIsPaused: Bool
    switch debugPhase {
    case .idle, .failed:
      debugIsActive = false
      debugIsRunning = false
      debugIsPaused = false
    case .starting:
      debugIsActive = true
      debugIsRunning = false
      debugIsPaused = false
    case .running:
      debugIsActive = true
      debugIsRunning = true
      debugIsPaused = false
    case .stopped:
      debugIsActive = true
      debugIsRunning = false
      debugIsPaused = true
    }

    return EditorCommandAvailability(
      hasDocument: activeTab != nil,
      hasUnsavedDocuments: hasUnsavedDocuments,
      canSave: activeTab != nil,
      canSaveAll: hasUnsavedDocuments,
      canBuild: canBuild,
      canRun: canRun,
      canTest: EditorBuildTaskResolver.canExecute(
        projectPlan: projectPlan, activeFileURL: activeFileURL, kind: .test),
      canCheck: EditorBuildTaskResolver.canExecute(
        projectPlan: projectPlan, activeFileURL: activeFileURL, kind: .check),
      isBuilding: isBuilding,
      canStartDebug: activeTab != nil && !debugIsActive && !isBuilding,
      debugIsActive: debugIsActive,
      debugIsRunning: debugIsRunning,
      debugIsPaused: debugIsPaused
    )
  }
}

extension MainView {
  var commandAvailability: EditorCommandAvailability {
    let base = controller.commandAvailability
    let selectedDocumentIsActive: Bool
    if case .document(let selectedID) = workspaceTabs.selection {
      selectedDocumentIsActive = controller.activeTab?.id == selectedID
    } else {
      selectedDocumentIsActive = false
    }

    return EditorCommandAvailability(
      hasDocument: selectedDocumentIsActive,
      hasUnsavedDocuments: base.hasUnsavedDocuments,
      canSave: selectedDocumentIsActive
        || (workspaceTabs.selection == .themeBuilder && themeBuilderSession.isDirty),
      canSaveAll: base.hasUnsavedDocuments,
      canBuild: base.canBuild,
      canRun: base.canRun,
      canTest: base.canTest,
      canCheck: base.canCheck,
      isBuilding: base.isBuilding,
      canStartDebug: selectedDocumentIsActive && base.canStartDebug,
      debugIsActive: base.debugIsActive,
      debugIsRunning: base.debugIsRunning,
      debugIsPaused: base.debugIsPaused
    )
  }
}
