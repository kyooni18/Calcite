import Foundation

/// Platform-neutral modifier state used by Calcite's native keyboard adapter.
@_spi(Calcite)
public struct VimKeyModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let shift = VimKeyModifiers(rawValue: 1 << 0)
  public static let control = VimKeyModifiers(rawValue: 1 << 1)
  public static let option = VimKeyModifiers(rawValue: 1 << 2)
  public static let command = VimKeyModifiers(rawValue: 1 << 3)
}

/// Special keys that have stable Vim notation independent of keyboard layout.
@_spi(Calcite)
public enum VimSpecialKey: Hashable, Sendable {
  case escape
  case returnKey
  case tab
  case backspace
  case delete
  case home
  case end
  case left
  case right
  case up
  case down
  case pageUp
  case pageDown
}

/// A physical key position expressed without platform key-code dependencies.
/// Character cases use the canonical US-QWERTY glyphs for that key position.
@_spi(Calcite)
public enum VimPhysicalKey: Hashable, Sendable {
  case character(unshifted: Character, shifted: Character? = nil)
  case special(VimSpecialKey)
  case unknown(Int)
}

/// A complete keyboard event before Vim command interpretation.
@_spi(Calcite)
public struct VimKeyStroke: Hashable, Sendable {
  public var physicalKey: VimPhysicalKey
  public var logicalText: String?
  public var textIgnoringModifiers: String?
  public var modifiers: VimKeyModifiers
  public var isRepeat: Bool
  public var isFromInputMethod: Bool

  public init(
    physicalKey: VimPhysicalKey,
    logicalText: String? = nil,
    textIgnoringModifiers: String? = nil,
    modifiers: VimKeyModifiers = [],
    isRepeat: Bool = false,
    isFromInputMethod: Bool = false
  ) {
    self.physicalKey = physicalKey
    self.logicalText = logicalText
    self.textIgnoringModifiers = textIgnoringModifiers
    self.modifiers = modifiers
    self.isRepeat = isRepeat
    self.isFromInputMethod = isFromInputMethod
  }
}

/// Determines how command keys are interpreted while a non-Latin or alternate
/// keyboard layout is active. Literal text arguments always remain logical text.
@_spi(Calcite)
public enum VimCommandKeyboardPolicy: String, Hashable, Sendable, Codable, CaseIterable {
  /// Physical US-QWERTY positions for commands, native logical text for insertion
  /// and literal arguments. This is the recommended multilingual behavior.
  case automatic
  /// Use the text produced by the active keyboard layout for commands.
  case logical
  /// Always use canonical US-QWERTY physical positions for command keys.
  case physicalUS
  /// Use logical text after applying the controller's user-defined language map.
  case languageMap
}

/// Describes the parser's next input requirement so host adapters can route
/// command keys and native text input without guessing from the current mode.
@_spi(Calcite)
public enum VimExpectedInput: Hashable, Sendable {
  case command
  case literalCharacter
  case registerName
  case markName
  case replacementCharacter
  case promptText
}

/// Typed input accepted by `VimKeymapController`.
@_spi(Calcite)
public enum VimInputEvent: Hashable, Sendable {
  case key(VimKeyStroke)
  case textCommit(String, replacementRange: Range<Int>? = nil)
  case compositionStarted
  case compositionUpdated(String, selectedRange: Range<Int>)
  case compositionCommitted(String)
  case compositionCancelled
  case mappingTimeout
}

/// Runtime token used by the mapping trie and parser queue. Notation strings are
/// retained only at the legacy API and Vim parser boundaries.
struct VimInputToken: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case text(String)
    case special(VimSpecialKey)
    case modified(VimKeyModifiers, String)
    case notation(String)
  }

  var kind: Kind

  init(kind: Kind) {
    self.kind = kind
  }

  init(notationToken token: String) {
    let lower = token.lowercased()
    switch lower {
    case "<esc>", "<c-[>": self.kind = .special(.escape)
    case "<cr>", "<enter>": self.kind = .special(.returnKey)
    case "<tab>": self.kind = .special(.tab)
    case "<bs>", "<backspace>": self.kind = .special(.backspace)
    case "<del>", "<delete>": self.kind = .special(.delete)
    case "<home>": self.kind = .special(.home)
    case "<end>": self.kind = .special(.end)
    case "<left>": self.kind = .special(.left)
    case "<right>": self.kind = .special(.right)
    case "<up>": self.kind = .special(.up)
    case "<down>": self.kind = .special(.down)
    case "<pageup>": self.kind = .special(.pageUp)
    case "<pagedown>": self.kind = .special(.pageDown)
    default:
      if lower.hasPrefix("<c-"), lower.hasSuffix(">") {
        let value = String(lower.dropFirst(3).dropLast())
        self.kind = .modified(.control, value)
      } else if lower.hasPrefix("<m-"), lower.hasSuffix(">") {
        let value = String(token.dropFirst(3).dropLast())
        self.kind = .modified(.option, value)
      } else if token.hasPrefix("<"), token.hasSuffix(">") {
        self.kind = .notation(token)
      } else {
        self.kind = .text(token)
      }
    }
  }

  var notation: String {
    switch kind {
    case .text(let value):
      return value
    case .special(let key):
      switch key {
      case .escape: return "<Esc>"
      case .returnKey: return "<CR>"
      case .tab: return "<Tab>"
      case .backspace: return "<BS>"
      case .delete: return "<Del>"
      case .home: return "<Home>"
      case .end: return "<End>"
      case .left: return "<Left>"
      case .right: return "<Right>"
      case .up: return "<Up>"
      case .down: return "<Down>"
      case .pageUp: return "<PageUp>"
      case .pageDown: return "<PageDown>"
      }
    case .modified(let modifiers, let value):
      var components: [String] = []
      if modifiers.contains(.control) { components.append("C") }
      if modifiers.contains(.option) { components.append("M") }
      if modifiers.contains(.shift) { components.append("S") }
      if modifiers.contains(.command) { components.append("D") }
      return "<\(components.joined(separator: "-"))-\(value)>"
    case .notation(let value):
      return value
    }
  }

  var text: String? {
    if case .text(let value) = kind { return value }
    return nil
  }
}

extension VimSpecialKey {
  var token: VimInputToken { VimInputToken(kind: .special(self)) }
}
