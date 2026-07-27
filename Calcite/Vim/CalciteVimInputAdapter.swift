import AppKit
@_spi(Calcite) import EditorVim

enum CalciteVimInputAdapter {
  static func keyStroke(for event: NSEvent) -> VimKeyStroke? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: VimKeyModifiers = []
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.command) { modifiers.insert(.command) }

    let physicalKey = physicalKey(for: event.keyCode)
    let logicalText = event.characters
    let ignoringModifiers = event.charactersIgnoringModifiers
    if case .unknown = physicalKey,
      logicalText?.isEmpty != false,
      ignoringModifiers?.isEmpty != false
    {
      return nil
    }
    return VimKeyStroke(
      physicalKey: physicalKey,
      logicalText: logicalText,
      textIgnoringModifiers: ignoringModifiers,
      modifiers: modifiers,
      isRepeat: event.isARepeat,
      isFromInputMethod: false
    )
  }

  private static func physicalKey(for keyCode: UInt16) -> VimPhysicalKey {
    switch keyCode {
    case 0: return .character(unshifted: "a", shifted: "A")
    case 1: return .character(unshifted: "s", shifted: "S")
    case 2: return .character(unshifted: "d", shifted: "D")
    case 3: return .character(unshifted: "f", shifted: "F")
    case 4: return .character(unshifted: "h", shifted: "H")
    case 5: return .character(unshifted: "g", shifted: "G")
    case 6: return .character(unshifted: "z", shifted: "Z")
    case 7: return .character(unshifted: "x", shifted: "X")
    case 8: return .character(unshifted: "c", shifted: "C")
    case 9: return .character(unshifted: "v", shifted: "V")
    case 11: return .character(unshifted: "b", shifted: "B")
    case 12: return .character(unshifted: "q", shifted: "Q")
    case 13: return .character(unshifted: "w", shifted: "W")
    case 14: return .character(unshifted: "e", shifted: "E")
    case 15: return .character(unshifted: "r", shifted: "R")
    case 16: return .character(unshifted: "y", shifted: "Y")
    case 17: return .character(unshifted: "t", shifted: "T")
    case 18: return .character(unshifted: "1", shifted: "!")
    case 19: return .character(unshifted: "2", shifted: "@")
    case 20: return .character(unshifted: "3", shifted: "#")
    case 21: return .character(unshifted: "4", shifted: "$")
    case 22: return .character(unshifted: "6", shifted: "^")
    case 23: return .character(unshifted: "5", shifted: "%")
    case 24: return .character(unshifted: "=", shifted: "+")
    case 25: return .character(unshifted: "9", shifted: "(")
    case 26: return .character(unshifted: "7", shifted: "&")
    case 27: return .character(unshifted: "-", shifted: "_")
    case 28: return .character(unshifted: "8", shifted: "*")
    case 29: return .character(unshifted: "0", shifted: ")")
    case 30: return .character(unshifted: "]", shifted: "}")
    case 31: return .character(unshifted: "o", shifted: "O")
    case 32: return .character(unshifted: "u", shifted: "U")
    case 33: return .character(unshifted: "[", shifted: "{")
    case 34: return .character(unshifted: "i", shifted: "I")
    case 35: return .character(unshifted: "p", shifted: "P")
    case 36, 76: return .special(.returnKey)
    case 37: return .character(unshifted: "l", shifted: "L")
    case 38: return .character(unshifted: "j", shifted: "J")
    case 39: return .character(unshifted: "'", shifted: "\"")
    case 40: return .character(unshifted: "k", shifted: "K")
    case 41: return .character(unshifted: ";", shifted: ":")
    case 42: return .character(unshifted: "\\", shifted: "|")
    case 43: return .character(unshifted: ",", shifted: "<")
    case 44: return .character(unshifted: "/", shifted: "?")
    case 45: return .character(unshifted: "n", shifted: "N")
    case 46: return .character(unshifted: "m", shifted: "M")
    case 47: return .character(unshifted: ".", shifted: ">")
    case 48: return .special(.tab)
    case 49: return .character(unshifted: " ")
    case 50: return .character(unshifted: "`", shifted: "~")
    case 51: return .special(.backspace)
    case 53: return .special(.escape)
    case 115: return .special(.home)
    case 116: return .special(.pageUp)
    case 117: return .special(.delete)
    case 119: return .special(.end)
    case 121: return .special(.pageDown)
    case 123: return .special(.left)
    case 124: return .special(.right)
    case 125: return .special(.down)
    case 126: return .special(.up)
    default: return .unknown(Int(keyCode))
    }
  }
}
