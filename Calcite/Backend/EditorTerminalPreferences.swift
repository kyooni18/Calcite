#if os(macOS)
  import Combine
  import Foundation

  nonisolated enum EditorTerminalAppearanceSource: String, Codable, CaseIterable, Sendable {
    case custom
    case macOSTerminal

    var title: String {
      switch self {
      case .custom: return "Custom"
      case .macOSTerminal: return "Terminal Profile"
      }
    }
  }

  nonisolated struct EditorTerminalColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
      self.red = red
      self.green = green
      self.blue = blue
      self.alpha = alpha
    }

    func normalized() -> Self {
      Self(
        red: red.clamped(to: 0...1),
        green: green.clamped(to: 0...1),
        blue: blue.clamped(to: 0...1),
        alpha: alpha.clamped(to: 0...1)
      )
    }
  }

  nonisolated struct EditorTerminalPreferences: Codable, Hashable, Sendable {
    var source: EditorTerminalAppearanceSource
    var fontName: String
    var fontSize: Double
    var foreground: EditorTerminalColor
    var background: EditorTerminalColor
    var selection: EditorTerminalColor
    var cursor: EditorTerminalColor
    var cursorStyle: EditorCursorStyle
    var backgroundOpacity: Double
    var horizontalPadding: Double
    var verticalPadding: Double
    var lineSpacing: Double
    var enablesLigatures: Bool
    var brightensBoldText: Bool
    var ansiColors: [EditorTerminalColor]

    init(
      source: EditorTerminalAppearanceSource,
      fontName: String,
      fontSize: Double,
      foreground: EditorTerminalColor,
      background: EditorTerminalColor,
      selection: EditorTerminalColor,
      cursor: EditorTerminalColor? = nil,
      cursorStyle: EditorCursorStyle = .line,
      backgroundOpacity: Double,
      horizontalPadding: Double,
      verticalPadding: Double,
      lineSpacing: Double,
      enablesLigatures: Bool,
      brightensBoldText: Bool,
      ansiColors: [EditorTerminalColor]
    ) {
      self.source = source
      self.fontName = fontName
      self.fontSize = fontSize
      self.foreground = foreground
      self.background = background
      self.selection = selection
      self.cursor = cursor ?? foreground
      self.cursorStyle = cursorStyle
      self.backgroundOpacity = backgroundOpacity
      self.horizontalPadding = horizontalPadding
      self.verticalPadding = verticalPadding
      self.lineSpacing = lineSpacing
      self.enablesLigatures = enablesLigatures
      self.brightensBoldText = brightensBoldText
      self.ansiColors = ansiColors
    }

    private enum CodingKeys: String, CodingKey {
      case source
      case fontName
      case fontSize
      case foreground
      case background
      case selection
      case cursor
      case cursorStyle
      case backgroundOpacity
      case horizontalPadding
      case verticalPadding
      case lineSpacing
      case enablesLigatures
      case brightensBoldText
      case ansiColors
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      source = try container.decode(EditorTerminalAppearanceSource.self, forKey: .source)
      fontName = try container.decode(String.self, forKey: .fontName)
      fontSize = try container.decode(Double.self, forKey: .fontSize)
      foreground = try container.decode(EditorTerminalColor.self, forKey: .foreground)
      background = try container.decode(EditorTerminalColor.self, forKey: .background)
      selection = try container.decode(EditorTerminalColor.self, forKey: .selection)
      cursor =
        try container.decodeIfPresent(EditorTerminalColor.self, forKey: .cursor) ?? foreground
      cursorStyle =
        try container.decodeIfPresent(EditorCursorStyle.self, forKey: .cursorStyle) ?? .line
      backgroundOpacity = try container.decode(Double.self, forKey: .backgroundOpacity)
      horizontalPadding = try container.decode(Double.self, forKey: .horizontalPadding)
      verticalPadding = try container.decode(Double.self, forKey: .verticalPadding)
      lineSpacing = try container.decode(Double.self, forKey: .lineSpacing)
      enablesLigatures = try container.decode(Bool.self, forKey: .enablesLigatures)
      brightensBoldText = try container.decode(Bool.self, forKey: .brightensBoldText)
      ansiColors = try container.decode([EditorTerminalColor].self, forKey: .ansiColors)
    }

    static let `default` = Self(
      source: .macOSTerminal,
      fontName: "Menlo-Regular",
      fontSize: 12.5,
      foreground: .init(red: 0.88, green: 0.88, blue: 0.88),
      background: .init(red: 0.08, green: 0.08, blue: 0.09),
      selection: .init(red: 0.25, green: 0.45, blue: 0.78, alpha: 0.55),
      cursor: .init(red: 0.42, green: 0.66, blue: 1),
      cursorStyle: .line,
      backgroundOpacity: 1,
      horizontalPadding: 10,
      verticalPadding: 7,
      lineSpacing: 0,
      enablesLigatures: false,
      brightensBoldText: true,
      ansiColors: defaultANSIColors
    )

    func normalized() -> Self {
      var value = self
      value.fontName = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.fontName.isEmpty { value.fontName = Self.default.fontName }
      value.fontSize = fontSize.clamped(to: 7...72)
      value.foreground = foreground.normalized()
      value.background = background.normalized()
      value.selection = selection.normalized()
      value.cursor = cursor.normalized()
      value.backgroundOpacity = backgroundOpacity.clamped(to: 0.2...1)
      value.horizontalPadding = horizontalPadding.clamped(to: 0...40)
      value.verticalPadding = verticalPadding.clamped(to: 0...40)
      value.lineSpacing = lineSpacing.clamped(to: 0...16)
      value.ansiColors = Array(ansiColors.prefix(16)).map { $0.normalized() }
      if value.ansiColors.count < 16 {
        value.ansiColors.append(
          contentsOf: Self.defaultANSIColors.dropFirst(value.ansiColors.count))
      }
      return value
    }

    static let defaultANSIColors: [EditorTerminalColor] = [
      .init(red: 0.00, green: 0.00, blue: 0.00),
      .init(red: 0.80, green: 0.00, blue: 0.00),
      .init(red: 0.00, green: 0.72, blue: 0.00),
      .init(red: 0.78, green: 0.68, blue: 0.00),
      .init(red: 0.20, green: 0.38, blue: 0.82),
      .init(red: 0.74, green: 0.18, blue: 0.74),
      .init(red: 0.00, green: 0.68, blue: 0.68),
      .init(red: 0.75, green: 0.75, blue: 0.75),
      .init(red: 0.40, green: 0.40, blue: 0.40),
      .init(red: 1.00, green: 0.28, blue: 0.28),
      .init(red: 0.28, green: 1.00, blue: 0.28),
      .init(red: 1.00, green: 1.00, blue: 0.28),
      .init(red: 0.38, green: 0.58, blue: 1.00),
      .init(red: 1.00, green: 0.38, blue: 1.00),
      .init(red: 0.28, green: 1.00, blue: 1.00),
      .init(red: 1.00, green: 1.00, blue: 1.00),
    ]
  }

  @MainActor
  final class EditorTerminalPreferencesStore: ObservableObject {
    @Published var preferences: EditorTerminalPreferences {
      didSet {
        revision &+= 1
        persist()
      }
    }

    @Published private(set) var revision: UInt64 = 0

    private let defaults: UserDefaults
    private static let defaultsKey = "editor.terminal.appearance.v2"

    init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
      if let data = defaults.data(forKey: Self.defaultsKey),
        let value = try? JSONDecoder().decode(EditorTerminalPreferences.self, from: data)
      {
        self.preferences = value.normalized()
      } else {
        self.preferences = .default
      }
    }

    func reset() {
      preferences = .default
    }

    func replace(with value: EditorTerminalPreferences) {
      preferences = value.normalized()
    }

    func apply(theme: EditorTerminalProfile) {
      var value = preferences
      value.source = .custom
      value.foreground = EditorTerminalColor(
        red: theme.foreground.red,
        green: theme.foreground.green,
        blue: theme.foreground.blue,
        alpha: theme.foreground.alpha
      )
      value.background = EditorTerminalColor(
        red: theme.background.red,
        green: theme.background.green,
        blue: theme.background.blue,
        alpha: theme.background.alpha
      )
      value.backgroundOpacity = theme.background.alpha
      value.ansiColors = theme.ansi.map {
        EditorTerminalColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
      }
      preferences = value.normalized()
    }

    func refresh() {
      revision &+= 1
    }

    private func persist() {
      guard let data = try? JSONEncoder().encode(preferences) else { return }
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }

  extension Double {
    nonisolated fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
      min(max(self, range.lowerBound), range.upperBound)
    }
  }
#endif
