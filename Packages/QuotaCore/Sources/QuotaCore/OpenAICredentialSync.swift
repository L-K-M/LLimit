import Foundation

/// Pure helpers for keeping an imported ChatGPT/Codex account's tokens in sync with the
/// live `~/.codex/auth.json` (or OpenCode) credentials.
///
/// OpenAI uses **rotating** refresh tokens: every successful refresh returns a new refresh
/// token and invalidates the previous one for sibling clients. LLimit imports a one-time
/// copy, so when the Codex CLI refreshes, LLimit's copy dies (and vice-versa). Re-reading
/// the live file and adopting its current token — matched by the stable ChatGPT account id,
/// and only when it is actually fresher — keeps the two in sync without ever downgrading
/// LLimit's own freshly-refreshed token back to a stale copy on disk.
public enum OpenAICredentialSync {
  /// Chooses the credentials to adopt for `stored` from the live on-disk logins, or nil if
  /// nothing should change.
  ///
  /// - Matches strictly by ChatGPT account id (never guesses across accounts): returns nil
  ///   when `stored` has no account id or no live login shares it.
  /// - Among same-account logins, picks the one whose access token expires latest.
  /// - Adopts only when that live token is strictly fresher than the stored one (or the
  ///   stored token is missing / not a decodable JWT), so LLimit never overwrites a token it
  ///   just refreshed with the stale copy still sitting in `~/.codex/auth.json`.
  ///
  /// `expiry` decodes a JWT access token's `exp` (inject `ChatGPTOAuth.accessTokenExpiry`).
  public static func adoption(
    for stored: [String: String],
    among live: [[String: String]],
    expiry: (String) -> Date?
  ) -> [String: String]? {
    let storedAccountID = (stored[CredentialField.openAIAccountID] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !storedAccountID.isEmpty else { return nil }

    let matches = live.filter { candidate in
      guard !(candidate[CredentialField.openAIAccessToken] ?? "").isEmpty else { return false }
      let candidateID = (candidate[CredentialField.openAIAccountID] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return candidateID == storedAccountID
    }
    guard !matches.isEmpty else { return nil }

    // The live login whose access token lives longest.
    guard let freshest = matches.max(by: { lhs, rhs in
      let l = expiry(lhs[CredentialField.openAIAccessToken] ?? "") ?? .distantPast
      let r = expiry(rhs[CredentialField.openAIAccessToken] ?? "") ?? .distantPast
      return l < r
    }) else { return nil }

    // Only adopt when strictly fresher than what we already hold.
    let storedAccess = stored[CredentialField.openAIAccessToken] ?? ""
    if let storedExp = storedAccess.isEmpty ? nil : expiry(storedAccess) {
      guard let freshExp = expiry(freshest[CredentialField.openAIAccessToken] ?? ""), freshExp > storedExp else {
        return nil
      }
    }

    return adopting(live: freshest, into: stored)
  }

  /// Returns a copy of `stored` with access/refresh/account-id values taken from `live`, or
  /// nil if nothing would change. It never blanks a field and only fills the account id when
  /// it is currently missing (the account id is the match key, so it must not be overwritten).
  static func adopting(
    live: [String: String],
    into stored: [String: String]
  ) -> [String: String]? {
    guard let liveAccess = live[CredentialField.openAIAccessToken], !liveAccess.isEmpty else {
      return nil
    }

    var updated = stored
    var changed = false

    if updated[CredentialField.openAIAccessToken] != liveAccess {
      updated[CredentialField.openAIAccessToken] = liveAccess
      changed = true
    }

    if let liveRefresh = live[CredentialField.openAIRefreshToken], !liveRefresh.isEmpty,
      updated[CredentialField.openAIRefreshToken] != liveRefresh
    {
      updated[CredentialField.openAIRefreshToken] = liveRefresh
      changed = true
    }

    if let liveAccountID = live[CredentialField.openAIAccountID], !liveAccountID.isEmpty,
      (updated[CredentialField.openAIAccountID] ?? "").isEmpty
    {
      updated[CredentialField.openAIAccountID] = liveAccountID
      changed = true
    }

    return changed ? updated : nil
  }
}
