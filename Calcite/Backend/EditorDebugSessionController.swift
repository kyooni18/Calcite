import Combine
import EditorServices
import Foundation

/// Owns the identity and presentation state of the active DAP session.
///
/// The workspace controller performs project-specific build and launch planning,
/// while this object is the sole authority for session generations. Delayed DAP
/// events must match both the local operation generation and the backend session
/// generation before they may update the UI.
@MainActor
final class EditorDebugSessionController: ObservableObject {
  @Published var phase: EditorDebugPhase = .idle

  var sourceFingerprint: String?
  var launchTarget: EditorDebugLaunchTarget?
  var language: EditorLanguage?
  var operationGeneration: UInt64 = 0
  var backendGeneration: UInt64?
  var operationID = UUID()
  var sessionID: UUID?
  var processLease: EditorProcessLease?
  var isReplacing = false

  @discardableResult
  func beginOperation(sessionID: UUID? = UUID()) -> UInt64 {
    operationGeneration &+= 1
    operationID = UUID()
    self.sessionID = sessionID
    phase = .starting
    return operationGeneration
  }

  func install(
    backendGeneration: UInt64,
    sourceFingerprint: String,
    language: EditorLanguage,
    launchTarget: EditorDebugLaunchTarget,
    sessionID: UUID
  ) {
    self.backendGeneration = backendGeneration
    self.sourceFingerprint = sourceFingerprint
    self.language = language
    self.launchTarget = launchTarget
    self.sessionID = sessionID
    if case .starting = phase { phase = .running }
  }

  func fail(_ message: String, clearIdentity: Bool = false) {
    if clearIdentity { clearIdentityState() }
    phase = .failed(message)
  }

  func finish() {
    operationGeneration &+= 1
    clearIdentityState()
    phase = .idle
  }


  func replaceProcessLease(with lease: EditorProcessLease?) -> EditorProcessLease? {
    let previous = processLease
    processLease = lease
    return previous
  }

  func takeProcessLease() -> EditorProcessLease? {
    replaceProcessLease(with: nil)
  }

  func acceptsOperation(_ generation: UInt64) -> Bool {
    generation == operationGeneration && !isReplacing
  }

  func acceptsBackend(_ generation: UInt64) -> Bool {
    backendGeneration == generation
  }

  private func clearIdentityState() {
    backendGeneration = nil
    sourceFingerprint = nil
    language = nil
    launchTarget = nil
    sessionID = nil
    isReplacing = false
  }
}
