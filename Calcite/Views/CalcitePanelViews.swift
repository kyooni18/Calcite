import SwiftUI
import EditorVim

@MainActor
struct CalciteProblemsView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    CalciteProblemsSurface(
      controller: backend.controller,
      buildController: backend.buildController,
      windowSession: windowSession
    )
  }
}

@MainActor
struct CalciteBuildOutputView: View {
  @ObservedObject var backend: CalciteBackend

  var body: some View {
    CalciteBuildOutputSurface(
      controller: backend.controller,
      buildController: backend.buildController
    )
  }
}

@MainActor
struct CalciteDebugPanelView: View {
  @ObservedObject var backend: CalciteBackend

  var body: some View {
    CalciteDebugPanelSurface(controller: backend.controller)
  }
}

@MainActor
struct CalciteTerminalView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    CalciteTerminalSurface(
      session: backend.terminal,
      themeProfile: backend.controller.profile.terminal,
      navigateSection: windowSession.commandNavigateSection(direction:),
      navigateTab: windowSession.commandNavigateTab(forward:),
      selectTab: windowSession.commandSelectTab(number:),
      handleHostCommand: { backend.handleVimHostRequest(.custom($0)) }
    )
  }
}
