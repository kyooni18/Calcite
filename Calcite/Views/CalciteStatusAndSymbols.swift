import EditorServices
import SwiftUI

/// the advanced status entry point.
@MainActor
struct CalciteStatusOverlay: View {
  @ObservedObject var backend: CalciteBackend

  var body: some View {
    CalciteStatusIndicator(
      store: backend.logStore,
      phase: backend.workspacePhase
    )
  }
}

/// the symbol-information popover entry point.
struct CalciteSymbolInformationPopover: View {
  let information: EditorSymbolInformation

  var body: some View {
    EditorSymbolInformationPopover(information: information)
  }
}

/// the symbol-location sheet entry point.
@MainActor
struct CalciteSymbolLocationsSheet: View {
  @ObservedObject var backend: CalciteBackend
  let collection: EditorSymbolLocationCollection

  var body: some View {
    EditorSymbolLocationsSheet(
      collection: collection,
      workspaceURL: backend.workspaceURL,
      open: { location in backend.openSymbolLocation(location) }
    )
  }
}
