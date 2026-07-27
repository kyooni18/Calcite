import Foundation

@_spi(Calcite)
public enum VimMappingMode: String, Hashable, Sendable, Codable, CaseIterable {
  case normal
  case insert
  case replace
  case visual
  case operatorPending
  case commandLine
}

@_spi(Calcite)
public enum VimMappingInputDomain: String, Hashable, Sendable, Codable, CaseIterable {
  case command
  case logicalText
}

@_spi(Calcite)
public struct VimKeyMappingV2: Hashable, Sendable {
  public var sequence: String
  public var command: String
  public var modes: Set<VimMappingMode>
  public var recursive: Bool
  public var nowait: Bool
  public var inputDomain: VimMappingInputDomain

  public init(
    sequence: String,
    command: String,
    modes: Set<VimMappingMode> = [.normal, .visual, .operatorPending],
    recursive: Bool = true,
    nowait: Bool = false,
    inputDomain: VimMappingInputDomain = .command
  ) {
    self.sequence = sequence
    self.command = command
    self.modes = modes
    self.recursive = recursive
    self.nowait = nowait
    self.inputDomain = inputDomain
  }
}

@_spi(Calcite)
public struct VimMappingConflict: Hashable, Sendable {
  public var sequence: String
  public var mode: VimMappingMode
  public var inputDomain: VimMappingInputDomain

  public init(
    sequence: String,
    mode: VimMappingMode,
    inputDomain: VimMappingInputDomain = .command
  ) {
    self.sequence = sequence
    self.mode = mode
    self.inputDomain = inputDomain
  }
}

struct VimMappingKey: Hashable {
  var mode: VimMappingMode
  var inputDomain: VimMappingInputDomain
}

struct VimResolvedMapping: Sendable {
  var invocation: VimInvocation
  var recursive: Bool
  var nowait: Bool
  var inputDomain: VimMappingInputDomain
}
