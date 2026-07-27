@_spi(Calcite) import EditorVim

enum CalciteVimConfigurationAdapter {
  static func mappings(from profiles: [EditorVimMappingProfile]) -> [VimKeyMappingV2] {
    profiles.map {
      VimKeyMappingV2(
        sequence: $0.sequence,
        command: $0.command,
        modes: Set($0.modes.map(mappingMode)),
        recursive: $0.recursive,
        nowait: $0.nowait,
        inputDomain: mappingInputDomain($0.inputDomain)
      )
    }
  }

  static func signature(
    profile: EditorVimProfile,
    tabWidth: Int,
    mappings: [VimKeyMappingV2]
  ) -> String {
    ([
      profile.normalizedLeader,
      String(tabWidth),
      profile.keyboardPolicy.rawValue,
      profile.languageMap,
      String(profile.mappingTimeoutMilliseconds),
    ]
      + mappings.map {
        "\($0.sequence)=\($0.command):\($0.modes.map(\.rawValue).sorted().joined(separator: ",")):\($0.recursive):\($0.nowait):\($0.inputDomain.rawValue)"
      })
      .joined(separator: "|")
  }

  static func inputPolicy(
    from policy: EditorVimKeyboardPolicy
  ) -> VimCommandKeyboardPolicy {
    switch policy {
    case .automatic: .automatic
    case .logical: .logical
    case .physicalUS: .physicalUS
    case .languageMap: .languageMap
    }
  }

  static func languageMap(from rawValue: String) -> [Character: Character] {
    let components = rawValue.split { character in
      character == "," || character == ";" || character.isWhitespace
    }
    var result: [Character: Character] = [:]
    for component in components {
      let value = String(component)
      if let separator = value.firstIndex(where: { $0 == "=" || $0 == ":" }) {
        let source = value[..<separator].first
        let target = value[value.index(after: separator)...].first
        if let source, let target { result[source] = target }
      } else {
        let characters = Array(value)
        if characters.count == 2 { result[characters[0]] = characters[1] }
      }
    }
    return result
  }

  private static func mappingMode(_ mode: EditorVimMappingMode) -> VimMappingMode {
    switch mode {
    case .normal: .normal
    case .insert: .insert
    case .replace: .replace
    case .visual: .visual
    case .operatorPending: .operatorPending
    case .commandLine: .commandLine
    }
  }

  private static func mappingInputDomain(
    _ domain: EditorVimMappingInputDomain
  ) -> VimMappingInputDomain {
    switch domain {
    case .command: .command
    case .logicalText: .logicalText
    }
  }
}
