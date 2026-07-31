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

    let canDebugCurrentFile: Bool = {
      guard let activeTab,
        let language = EditorLanguage.allCases.first(where: {
          $0.languageIDs.contains(activeTab.languageID)
        }),
        ideWorkspace?.serviceResult.debugAdapter(for: language) != nil
      else { return false }
      if usesProjectDebugContext(for: activeTab.url, language: language) {
        return true
      }
      return
        (try? EditorStandaloneDebugTarget.resolve(
          fileURL: activeTab.url, language: language
        )) != nil
    }()

    return EditorCommandAvailability(
      hasDocument: activeTab != nil,
      hasUnsavedDocuments: hasUnsavedDocuments,
      canSave: activeTab != nil,
      canSaveAll: hasUnsavedDocuments,
      canBuild: canBuild,
      canRun: canRun,
      canRunCurrentFile: activeFileURL.map {
        let resolution = EditorBuildDiscovery.singleFileResolution(
          fileURL: $0,
          workspaceURL: workspaceURL
        )
        switch resolution.capability {
        case .standalone, .projectContextRequired:
          return resolution.plan != nil
        case .temporaryProjectRequired, .toolMissing, .unsupported:
          return false
        }
      } ?? false,
      canTest: EditorBuildTaskResolver.canExecute(
        projectPlan: projectPlan, activeFileURL: activeFileURL, kind: .test),
      canCheck: EditorBuildTaskResolver.canExecute(
        projectPlan: projectPlan, activeFileURL: activeFileURL, kind: .check),
      isBuilding: isBuilding,
      canStartDebug: !debugIsActive && !isBuilding,
      canDebugCurrentFile: canDebugCurrentFile,
      debugIsActive: debugIsActive,
      debugIsRunning: debugIsRunning,
      debugIsPaused: debugIsPaused,
      liveDebugIsEnabled: isLiveDebugEnabled
    )
  }
}
