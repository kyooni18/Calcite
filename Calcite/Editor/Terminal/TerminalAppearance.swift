#if os(macOS)
  import AppKit

  @MainActor
  struct TerminalAppearance {
    var font: NSFont
    var foreground: NSColor
    var background: NSColor
    var selection: NSColor
    var ansiColors: [NSColor]
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var lineSpacing: CGFloat
    var enablesLigatures: Bool
    var brightensBoldText: Bool

    static func resolve(_ preferences: EditorTerminalPreferences) -> Self {
      let normalized = preferences.normalized()
      if normalized.source == .macOSTerminal, let profile = terminalProfile() {
        return profile
      }
      return custom(normalized)
    }

    static func importedTerminalProfile() -> EditorTerminalPreferences? {
      guard let profile = terminalProfile() else { return nil }
      return EditorTerminalPreferences(
        source: .custom,
        fontName: profile.font.fontName,
        fontSize: profile.font.pointSize,
        foreground: profile.foreground.terminalColor,
        background: profile.background.withAlphaComponent(1).terminalColor,
        selection: profile.selection.terminalColor,
        backgroundOpacity: profile.background.alphaComponent,
        horizontalPadding: profile.horizontalPadding,
        verticalPadding: profile.verticalPadding,
        lineSpacing: profile.lineSpacing,
        enablesLigatures: profile.enablesLigatures,
        brightensBoldText: profile.brightensBoldText,
        ansiColors: profile.ansiColors.map(\.terminalColor)
      )
    }

    func attributedString(for snapshot: TerminalRenderedSnapshot) -> NSAttributedString {
      let length = (snapshot.text as NSString).length
      return attributedString(for: snapshot, range: NSRange(location: 0, length: length))
    }

    func attributedString(
      for snapshot: TerminalRenderedSnapshot,
      range requestedRange: NSRange
    ) -> NSAttributedString {
      let source = snapshot.text as NSString
      let location = min(max(0, requestedRange.location), source.length)
      let length = min(max(0, requestedRange.length), source.length - location)
      let range = NSRange(location: location, length: length)
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = lineSpacing
      paragraphStyle.lineBreakMode = .byClipping

      let value = NSMutableAttributedString(
        string: source.substring(with: range),
        attributes: [
          .font: font,
          .foregroundColor: foreground,
          .ligature: enablesLigatures ? 1 : 0,
          .paragraphStyle: paragraphStyle,
        ]
      )
      for span in snapshot.styleSpans {
        let spanRange = NSRange(location: span.utf16Location, length: span.utf16Length)
        let intersection = NSIntersectionRange(spanRange, range)
        guard intersection.length > 0 else { continue }
        value.addAttributes(
          attributes(for: span.style, paragraphStyle: paragraphStyle),
          range: NSRange(
            location: intersection.location - range.location,
            length: intersection.length
          )
        )
      }
      return value
    }

    private func attributes(
      for style: TerminalTextStyle,
      paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
      var textColor = color(for: style.foreground, bold: style.isBold) ?? foreground
      var fillColor = color(for: style.background, bold: false) ?? background
      if style.isInverse { swap(&textColor, &fillColor) }
      if style.isDim { textColor = textColor.withAlphaComponent(0.62) }

      var result: [NSAttributedString.Key: Any] = [
        .font: styledFont(for: style),
        .foregroundColor: textColor,
        .ligature: enablesLigatures ? 1 : 0,
        .paragraphStyle: paragraphStyle,
      ]
      if style.background != nil || style.isInverse { result[.backgroundColor] = fillColor }
      if style.isUnderlined { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      return result
    }

    private func styledFont(for style: TerminalTextStyle) -> NSFont {
      var traits: NSFontTraitMask = []
      if style.isBold { traits.insert(.boldFontMask) }
      if style.isItalic { traits.insert(.italicFontMask) }
      guard !traits.isEmpty else { return font }
      return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    private func color(for color: TerminalANSIColor?, bold: Bool) -> NSColor? {
      guard let color else { return nil }
      switch color {
      case .indexed(let rawIndex):
        let index =
          brightensBoldText && bold && (0...7).contains(rawIndex) ? rawIndex + 8 : rawIndex
        if ansiColors.indices.contains(index) { return ansiColors[index] }
        if (16...231).contains(index) {
          let value = index - 16
          return NSColor(
            srgbRed: Self.cubeComponent(value / 36),
            green: Self.cubeComponent((value % 36) / 6),
            blue: Self.cubeComponent(value % 6),
            alpha: 1
          )
        }
        if (232...255).contains(index) {
          let value = CGFloat(8 + (index - 232) * 10) / 255
          return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        }
        return nil
      case .rgb(let red, let green, let blue):
        return NSColor(
          srgbRed: CGFloat(red) / 255,
          green: CGFloat(green) / 255,
          blue: CGFloat(blue) / 255,
          alpha: 1
        )
      }
    }

    private static func custom(_ preferences: EditorTerminalPreferences) -> Self {
      let font =
        NSFont(name: preferences.fontName, size: preferences.fontSize)
        ?? NSFont.userFixedPitchFont(ofSize: preferences.fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
      let background = NSColor(preferences.background).withAlphaComponent(
        preferences.background.alpha * preferences.backgroundOpacity
      )
      return Self(
        font: font,
        foreground: NSColor(preferences.foreground),
        background: background,
        selection: NSColor(preferences.selection),
        ansiColors: preferences.ansiColors.map(NSColor.init),
        horizontalPadding: preferences.horizontalPadding,
        verticalPadding: preferences.verticalPadding,
        lineSpacing: preferences.lineSpacing,
        enablesLigatures: preferences.enablesLigatures,
        brightensBoldText: preferences.brightensBoldText
      )
    }

    private static func terminalProfile() -> Self? {
      guard let defaults = UserDefaults(suiteName: "com.apple.Terminal"),
        let profileName = defaults.string(forKey: "Default Window Settings"),
        let settings = defaults.dictionary(forKey: "Window Settings")?[profileName]
          as? [String: Any]
      else { return nil }

      let fallback = custom(.default)
      let palette = ansiColorKeys.enumerated().map { index, key in
        decode(NSColor.self, value: settings[key]) ?? fallback.ansiColors[index]
      }
      let background =
        decode(NSColor.self, value: settings["BackgroundColor"])
        ?? fallback.background
      let opacity = (settings["BackgroundOpacity"] as? NSNumber)?.doubleValue
      let selection =
        decode(NSColor.self, value: settings["SelectionColor"])
        ?? fallback.selection

      return Self(
        font: decode(NSFont.self, value: settings["Font"]) ?? fallback.font,
        foreground: decode(NSColor.self, value: settings["TextColor"]) ?? fallback.foreground,
        background: background.withAlphaComponent(
          opacity.map { CGFloat(min(max($0, 0), 1)) } ?? background.alphaComponent
        ),
        selection: selection,
        ansiColors: palette,
        horizontalPadding: fallback.horizontalPadding,
        verticalPadding: fallback.verticalPadding,
        lineSpacing: fallback.lineSpacing,
        enablesLigatures: fallback.enablesLigatures,
        brightensBoldText: (settings["UseBrightBold"] as? NSNumber)?.boolValue ?? true
      )
    }

    private static func cubeComponent(_ value: Int) -> CGFloat {
      CGFloat(value == 0 ? 0 : 55 + value * 40) / 255
    }

    private static func decode<T: NSObject & NSSecureCoding>(
      _ type: T.Type,
      value: Any?
    ) -> T? {
      guard let data = value as? Data else { return nil }
      return try? NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data)
    }

    private static let ansiColorKeys = [
      "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
      "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
      "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor",
      "ANSIBrightYellowColor", "ANSIBrightBlueColor", "ANSIBrightMagentaColor",
      "ANSIBrightCyanColor", "ANSIBrightWhiteColor",
    ]
  }

  extension NSColor {
    fileprivate convenience init(_ value: EditorTerminalColor) {
      self.init(
        srgbRed: value.red,
        green: value.green,
        blue: value.blue,
        alpha: value.alpha
      )
    }

    fileprivate var terminalColor: EditorTerminalColor {
      let color = usingColorSpace(.sRGB) ?? self
      return EditorTerminalColor(
        red: color.redComponent,
        green: color.greenComponent,
        blue: color.blueComponent,
        alpha: color.alphaComponent
      )
    }
  }
#endif
