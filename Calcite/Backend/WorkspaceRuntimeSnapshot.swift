@_spi(Calcite) import EditorVim
import Foundation

nonisolated struct WorkspaceTextRangeSnapshot: Codable, Equatable, Sendable {
  var location: Int
  var length: Int

  init(_ range: NSRange) {
    location = max(0, range.location)
    length = max(0, range.length)
  }

  var nsRange: NSRange {
    NSRange(location: max(0, location), length: max(0, length))
  }
}

nonisolated struct WorkspaceDocumentRuntimeSnapshot: Equatable, Sendable {
  var id: UUID
  var url: URL
  var selectedRange: WorkspaceTextRangeSnapshot
  var text: String
  var isDirty: Bool
  var diskModificationTime: TimeInterval?
}

nonisolated struct WorkspaceDocumentPresentationSnapshot: Codable, Equatable, Sendable {
  var documentID: UUID
  var selectedRange: WorkspaceTextRangeSnapshot
  var horizontalScrollOffset: Double
  var verticalScrollOffset: Double
  var zoomScale: Double
}

nonisolated struct WorkspaceEditorPresentationSnapshot: Codable, Equatable, Sendable {
  var editorSessionID: UUID
  var documentID: UUID
  var selectedRange: WorkspaceTextRangeSnapshot
  var horizontalScrollOffset: Double
  var verticalScrollOffset: Double
  var zoomScale: Double
  var vimRuntime: VimViewRuntimeSnapshot?
  var documentPresentations: [WorkspaceDocumentPresentationSnapshot]

  init(
    editorSessionID: UUID,
    documentID: UUID,
    selectedRange: WorkspaceTextRangeSnapshot,
    horizontalScrollOffset: Double,
    verticalScrollOffset: Double,
    zoomScale: Double,
    vimRuntime: VimViewRuntimeSnapshot? = nil,
    documentPresentations: [WorkspaceDocumentPresentationSnapshot] = []
  ) {
    self.editorSessionID = editorSessionID
    self.documentID = documentID
    self.selectedRange = selectedRange
    self.horizontalScrollOffset = horizontalScrollOffset
    self.verticalScrollOffset = verticalScrollOffset
    self.zoomScale = zoomScale
    self.vimRuntime = vimRuntime
    self.documentPresentations = documentPresentations
  }

  private enum CodingKeys: String, CodingKey {
    case editorSessionID
    case documentID
    case selectedRange
    case horizontalScrollOffset
    case verticalScrollOffset
    case zoomScale
    case vimRuntime
    case documentPresentations
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    editorSessionID = try container.decode(UUID.self, forKey: .editorSessionID)
    documentID = try container.decode(UUID.self, forKey: .documentID)
    selectedRange = try container.decode(WorkspaceTextRangeSnapshot.self, forKey: .selectedRange)
    horizontalScrollOffset = try container.decode(Double.self, forKey: .horizontalScrollOffset)
    verticalScrollOffset = try container.decode(Double.self, forKey: .verticalScrollOffset)
    zoomScale = try container.decode(Double.self, forKey: .zoomScale)
    vimRuntime = try container.decodeIfPresent(VimViewRuntimeSnapshot.self, forKey: .vimRuntime)
    documentPresentations =
      try container.decodeIfPresent(
        [WorkspaceDocumentPresentationSnapshot].self,
        forKey: .documentPresentations
      ) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(editorSessionID, forKey: .editorSessionID)
    try container.encode(documentID, forKey: .documentID)
    try container.encode(selectedRange, forKey: .selectedRange)
    try container.encode(horizontalScrollOffset, forKey: .horizontalScrollOffset)
    try container.encode(verticalScrollOffset, forKey: .verticalScrollOffset)
    try container.encode(zoomScale, forKey: .zoomScale)
    try container.encodeIfPresent(vimRuntime, forKey: .vimRuntime)
    if !documentPresentations.isEmpty {
      try container.encode(documentPresentations, forKey: .documentPresentations)
    }
  }
}

nonisolated struct WorkspaceSectionEditorAssignmentSnapshot: Codable, Equatable, Sendable {
  var sectionID: UUID
  var editorSessionID: UUID
}

nonisolated struct WorkspaceWindowPresentationSnapshot: Codable, Equatable, Sendable {
  var windowSessionID: UUID
  var activeEditorSessionID: UUID?
  var activeSectionID: UUID?
  var editors: [WorkspaceEditorPresentationSnapshot]
  var sectionAssignments: [WorkspaceSectionEditorAssignmentSnapshot]
}

nonisolated struct WorkspacePresentationSnapshot: Codable, Equatable, Sendable {
  var activeWindowSessionID: UUID?
  var windows: [WorkspaceWindowPresentationSnapshot]

  static let empty = WorkspacePresentationSnapshot(
    activeWindowSessionID: nil,
    windows: []
  )
}

nonisolated struct WorkspaceRuntimeSnapshot: Equatable, Sendable {
  var documents: [WorkspaceDocumentRuntimeSnapshot]
  var selectedDocumentID: UUID?
  var presentation: WorkspacePresentationSnapshot
}
