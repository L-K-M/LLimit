import Foundation

/// Detaches a profile only after its recovery record and the account change have
/// been saved. This applies to both account removal and replacement on reconnect.
public enum ClaudeCodeProfileRetirement {
  public enum Outcome: Equatable, Sendable {
    case removed
    case retained
  }

  /// `retain` and `commitAccountChange` must finish their durable writes before
  /// returning. If the account commit fails, its retention record can still name
  /// an active profile. Later cleanup must check current account references and
  /// must never infer that a retention record alone authorizes deletion. The
  /// deletion callback must preserve a recoverable record if cleanup fails.
  public static func commit(
    stored: [String: String], refreshLocked: Bool,
    retain: (ClaudeCodeProfile) throws -> Void,
    commitAccountChange: () throws -> Void,
    deleteProfile: (ClaudeCodeProfile) throws -> Void
  ) throws -> Outcome {
    guard let profile = ClaudeCodeProfile.profile(from: stored) else {
      try commitAccountChange()
      return .removed
    }

    try retain(profile)
    try commitAccountChange()
    guard stored[CredentialField.anthropicRenewalPending] == nil, !refreshLocked else {
      return .retained
    }

    do {
      // Successful cleanup includes the retained-profile record.
      try deleteProfile(profile)
      return .removed
    } catch {
      return .retained
    }
  }
}
