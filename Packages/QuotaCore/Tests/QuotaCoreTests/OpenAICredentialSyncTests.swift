import XCTest
@testable import QuotaCore

final class OpenAICredentialSyncTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func creds(access: String, refresh: String? = nil, account: String? = nil) -> [String: String] {
    var d = [CredentialField.openAIAccessToken: access]
    if let refresh { d[CredentialField.openAIRefreshToken] = refresh }
    if let account { d[CredentialField.openAIAccountID] = account }
    return d
  }

  /// Deterministic fake JWT-expiry map keyed by access-token string.
  private func expiryMap(_ pairs: [String: Date]) -> (String) -> Date? {
    { pairs[$0] }
  }

  // MARK: - account-id matching

  func testAdoptsFresherSameAccountToken() {
    let stored = creds(access: "old", refresh: "r0", account: "acct_A")
    let live = [creds(access: "newA", refresh: "r1", account: "acct_A")]
    let exp = expiryMap(["old": base, "newA": base.addingTimeInterval(3600)])

    let updated = OpenAICredentialSync.adoption(for: stored, among: live, expiry: exp)
    XCTAssertEqual(updated?[CredentialField.openAIAccessToken], "newA")
    XCTAssertEqual(updated?[CredentialField.openAIRefreshToken], "r1")
  }

  func testNoMatchWhenAccountIDAbsentFromLive() {
    let stored = creds(access: "old", account: "acct_A")
    let live = [creds(access: "newB", account: "acct_B")]
    XCTAssertNil(OpenAICredentialSync.adoption(for: stored, among: live, expiry: { _ in nil }))
  }

  func testNoMatchWhenStoredHasNoAccountID() {
    // Conservative: without an account id we can't be sure which login is "ours".
    let stored = creds(access: "old")
    let live = [creds(access: "new", account: "acct_A")]
    XCTAssertNil(OpenAICredentialSync.adoption(for: stored, among: live, expiry: { _ in nil }))
  }

  // MARK: - freshness gate (the brick-prevention fix)

  func testDoesNotDowngradeToStaleFileToken() {
    // LLimit already refreshed to a longer-lived token; the file still holds the old one.
    let stored = creds(access: "fresh", refresh: "r_fresh", account: "acct_A")
    let live = [creds(access: "stale", refresh: "r_stale", account: "acct_A")]
    let exp = expiryMap(["fresh": base.addingTimeInterval(3600), "stale": base])

    XCTAssertNil(OpenAICredentialSync.adoption(for: stored, among: live, expiry: exp))
  }

  func testAdoptsWhenStoredTokenNotDecodable() {
    let stored = creds(access: "opaque", account: "acct_A")
    let live = [creds(access: "jwt", account: "acct_A")]
    let exp = expiryMap(["jwt": base.addingTimeInterval(3600)]) // "opaque" -> nil

    let updated = OpenAICredentialSync.adoption(for: stored, among: live, expiry: exp)
    XCTAssertEqual(updated?[CredentialField.openAIAccessToken], "jwt")
  }

  func testPicksFreshestAmongMultipleSameAccountLogins() {
    let stored = creds(access: "old", account: "acct_A")
    let live = [
      creds(access: "codex", refresh: "rc", account: "acct_A"),
      creds(access: "opencode", refresh: "ro", account: "acct_A")
    ]
    let exp = expiryMap([
      "old": base,
      "codex": base.addingTimeInterval(600),
      "opencode": base.addingTimeInterval(7200)
    ])

    let updated = OpenAICredentialSync.adoption(for: stored, among: live, expiry: exp)
    XCTAssertEqual(updated?[CredentialField.openAIAccessToken], "opencode")
  }

  func testReturnsNilWhenNothingChanges() {
    let same = creds(access: "same", refresh: "r", account: "acct_A")
    let exp = expiryMap(["same": base.addingTimeInterval(3600)])
    // Freshest match equals stored -> not strictly fresher -> nil.
    XCTAssertNil(OpenAICredentialSync.adoption(for: same, among: [same], expiry: exp))
  }

  // MARK: - adopting (mechanical merge)

  func testAdoptingDoesNotOverwriteExistingAccountID() {
    let stored = creds(access: "old", account: "acct_A")
    let live = creds(access: "new", account: "acct_DIFFERENT")
    let updated = OpenAICredentialSync.adopting(live: live, into: stored)
    XCTAssertEqual(updated?[CredentialField.openAIAccountID], "acct_A")
  }

  func testAdoptingNeverBlanksRefreshTokenWhenLiveLacksIt() {
    let stored = creds(access: "old", refresh: "r_keep", account: "acct_A")
    let live = creds(access: "new", account: "acct_A")
    let updated = OpenAICredentialSync.adopting(live: live, into: stored)
    XCTAssertEqual(updated?[CredentialField.openAIRefreshToken], "r_keep")
  }
}
