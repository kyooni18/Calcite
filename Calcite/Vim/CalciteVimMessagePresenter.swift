@_spi(Calcite) import EditorVim
import Foundation

@MainActor
enum CalciteVimMessagePresenter {
  static func message(for error: Error) -> VimMessage {
    guard let vimError = error as? VimError else {
      return VimMessage(
        text: error.localizedDescription,
        severity: .error,
        lifetime: .timed(milliseconds: 3200)
      )
    }
    switch vimError {
    case .invalidCount:
      return VimMessage(
        text: "Invalid range or count",
        code: "E16",
        severity: .error,
        lifetime: .timed(milliseconds: 2800)
      )
    case .invalidRegister:
      return VimMessage(
        text: "Invalid register name",
        code: "E354",
        severity: .error,
        lifetime: .timed(milliseconds: 2800)
      )
    case .unsupportedNotation(let notation):
      return VimMessage(
        text: "Unsupported command: \(notation)",
        code: "E492",
        severity: .error,
        lifetime: .timed(milliseconds: 3200)
      )
    case .incompleteCommand(let command):
      return VimMessage(
        text: "Incomplete command: \(command)",
        code: "E474",
        severity: .error,
        lifetime: .timed(milliseconds: 2800)
      )
    case .macroRecursionLimit:
      return VimMessage(
        text: "Recursive mapping or macro exceeded the limit",
        code: "E169",
        severity: .error,
        lifetime: .persistent
      )
    }
  }
}
