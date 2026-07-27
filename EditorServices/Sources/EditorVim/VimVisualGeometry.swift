import Foundation

@_spi(Calcite)
public struct VimVisualMovement: Hashable, Sendable {
  public var utf16Offset: Int
  public var preferredColumn: Int

  public init(utf16Offset: Int, preferredColumn: Int) {
    self.utf16Offset = utf16Offset
    self.preferredColumn = preferredColumn
  }
}

/// Optional host geometry used for proportional fonts, soft wrapping, tabs,
/// bidirectional runs, and platform text-layout behavior. Returning nil from any
/// method selects EditorVim's deterministic display-column fallback.
@_spi(Calcite)
public protocol VimVisualGeometryProviding: AnyObject, Sendable {
  func visualColumn(
    atUTF16Offset offset: Int,
    logicalLineStart: Int,
    text: String
  ) -> Int?

  func utf16Offset(
    inLogicalLineStartingAt lineStart: Int,
    atVisualColumn column: Int,
    contentEnd: Int,
    text: String,
    roundForward: Bool
  ) -> Int?

  func visualWidth(
    atUTF16Offset offset: Int,
    logicalLineStart: Int,
    text: String
  ) -> Int?

  func moveVertically(
    fromUTF16Offset offset: Int,
    direction: Int,
    preferredColumn: Int?,
    text: String
  ) -> VimVisualMovement?
}

extension VimEngine {
  @_spi(Calcite)
  public func installVisualGeometryProvider(
    _ provider: (any VimVisualGeometryProviding)?
  ) {
    lock.withLock { storedVisualGeometryProvider = provider }
  }
}
