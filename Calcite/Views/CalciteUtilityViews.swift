import SwiftUI

/// the settings detail entry point.
@MainActor
struct CalciteSettingsView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    ServiceSettingsView(
      controller: backend.controller,
      openFile: { url in
        Task { @MainActor in
          _ = await windowSession.openDocument(at: url)
        }
      }
    )
  }
}

/// the theme-builder detail entry point.
@MainActor
struct CalciteThemeBuilderView: View {
  @ObservedObject var backend: CalciteBackend
  @ObservedObject var windowSession: CalciteBackendWindowSession

  var body: some View {
    ThemeBuilderView(
      controller: backend.controller,
      session: windowSession.themeBuilderSession
    )
  }
}
