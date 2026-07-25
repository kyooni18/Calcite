import SwiftUI

/// The adaptive translucent background used by Calcite surfaces.
///
/// The background adopts Liquid Glass on macOS 26 and falls back to an
/// ultra-thin material on earlier supported versions of macOS.
public struct CalciteBackground<BackgroundShape: Shape>: View {
  private let shape: BackgroundShape

  public init(in shape: BackgroundShape) {
    self.shape = shape
  }

  public var body: some View {
    if #available(macOS 26.0, *) {
      shape
        .fill(.clear)
        .glassEffect(.regular, in: shape)
    } else {
      shape
        .fill(.ultraThinMaterial)
    }
  }
}

extension CalciteBackground where BackgroundShape == Rectangle {
  public init() {
    self.init(in: Rectangle())
  }
}
