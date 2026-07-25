import SwiftUI

struct CalciteNowPlayingSurface: View {
  @ObservedObject var controller: NowPlayingController

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Group {
        if let artwork = controller.artwork, let image = NSImage(data: artwork) {
          Image(nsImage: image).resizable().scaledToFill()
        } else {
          Image(systemName: "music.note").resizable().scaledToFit().padding(18)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 52, height: 52)
      .background(.fill.tertiary)
      .clipShape(RoundedRectangle(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 5) {
        MarqueeText(value: controller.title, font: .callout.weight(.medium))
        MarqueeText(value: controller.artist, font: .caption, foregroundStyle: .init(.secondary))

        HStack(spacing: 20) {
          Button(action: controller.previousTrack) { Image(systemName: "backward.fill") }
          Button(action: controller.togglePlayback) {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
          }
          Button(action: controller.nextTrack) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .disabled(controller.source == nil)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(9)
    .background {
      let primary = Color(nsColor: controller.artworkAccent)
      let secondary = Color(nsColor: controller.artworkSecondaryAccent)
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(.thinMaterial)
        LinearGradient(
          colors: [primary.opacity(0.28), secondary.opacity(0.14), primary.opacity(0.045)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        RadialGradient(
          colors: [secondary.opacity(0.20), .clear],
          center: .topTrailing,
          startRadius: 0,
          endRadius: 150
        )
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(.white.opacity(0.09), lineWidth: 0.75)
      }
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
  }
}

private struct MarqueeText: View {
  let value: String
  let font: Font
  var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
  @State private var leftMost = false
  @State private var textWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @State private var animationDuration = 0.0
  @State private var previousValue = ""
  @State private var isAnimating = false

  var body: some View {
    GeometryReader { geometry in
      Group {
        if animationDuration > 0 {
          Text(value)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .modifier(
              SlidingEffect(
                xPosition: leftMost && isAnimating ? containerWidth - textWidth : 0
              )
            )
            .animation(
              .linear(duration: animationDuration).repeatForever(autoreverses: true),
              value: isAnimating
            )
        } else {
          Text(value)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .overlay(alignment: .leading) {
        Text(value)
          .font(font)
          .foregroundStyle(foregroundStyle)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .opacity(0)
          .background(TextGeometry())
          .allowsHitTesting(false)
      }
      .onPreferenceChange(MarqueeWidthKey.self) { width in
        textWidth = width
        containerWidth = geometry.size.width
        let overflowing = containerWidth > 1 && textWidth > containerWidth + 1
        animationDuration = overflowing ? max(3, Double(textWidth - containerWidth) / 25) : 0
        if value != previousValue {
          previousValue = value
          isAnimating = false
          leftMost = overflowing
          if overflowing {
            DispatchQueue.main.async { isAnimating = true }
          }
        }
      }
      .onChange(of: geometry.size.width) { _, width in
        containerWidth = width
        let overflowing = width > 1 && textWidth > width + 1
        animationDuration = overflowing ? max(3, Double(textWidth - width) / 25) : 0
        isAnimating = false
        leftMost = overflowing
        if overflowing {
          DispatchQueue.main.async { isAnimating = true }
        }
      }
    }
    .frame(height: 18)
    .clipped()
  }
}

private struct SlidingEffect: GeometryEffect {
  var xPosition: CGFloat
  var animatableData: CGFloat {
    get { xPosition }
    set { xPosition = newValue }
  }
  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: xPosition, y: 0))
  }
}

private struct TextGeometry: View {
  var body: some View {
    GeometryReader { geometry in
      Color.clear.preference(key: MarqueeWidthKey.self, value: geometry.size.width)
    }
  }
}

private struct MarqueeWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
