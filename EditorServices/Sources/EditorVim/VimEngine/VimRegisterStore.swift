import Foundation

struct VimRegisterStore: Sendable {
  private var values: [VimRegister: VimRegisterValue] = [:]

  func value(for register: VimRegister) -> VimRegisterValue {
    values[normalized(register)] ?? VimRegisterValue()
  }

  mutating func set(_ value: VimRegisterValue, for register: VimRegister) {
    guard register != .blackHole else { return }
    switch register {
    case .named(let name) where name.isUppercase:
      let lower = Character(String(name).lowercased())
      let existing = values[.named(lower)] ?? VimRegisterValue(kind: value.kind)
      values[.named(lower)] = VimRegisterValue(
        text: existing.text + value.text,
        kind: existing.kind == value.kind ? value.kind : .characterwise
      )
      values[.unnamed] = values[.named(lower)]
    default:
      values[normalized(register)] = value
      if register != .unnamed { values[.unnamed] = value }
    }
  }

  mutating func recordYank(_ value: VimRegisterValue, requested: VimRegister) {
    guard requested != .blackHole else { return }
    set(value, for: requested)
    values[.numbered(0)] = value
    values[.unnamed] = value
  }

  mutating func recordDelete(
    _ value: VimRegisterValue,
    requested: VimRegister,
    isSmall: Bool
  ) {
    guard requested != .blackHole else { return }
    set(value, for: requested)
    if isSmall, value.kind == .characterwise {
      values[.smallDelete] = value
    } else {
      for number in stride(from: 9, through: 2, by: -1) {
        values[.numbered(number)] = values[.numbered(number - 1)]
      }
      values[.numbered(1)] = value
    }
    values[.unnamed] = value
  }

  private func normalized(_ register: VimRegister) -> VimRegister {
    if case .named(let name) = register, name.isUppercase {
      return .named(Character(String(name).lowercased()))
    }
    return register
  }
}
