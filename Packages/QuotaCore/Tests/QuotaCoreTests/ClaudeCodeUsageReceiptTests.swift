import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeUsageReceiptTests: XCTestCase {
  private let firstProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let secondProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

  func testFetchBeforeLoginCompletionCannotSuppressNewFetch() {
    let receipt = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(-1))
    XCTAssertFalse(receipt.satisfies(profileID: firstProfile, since: completedAt))
  }

  func testFetchAtOrAfterLoginCompletionSuppressesDuplicateFetch() {
    for interval: TimeInterval in [0, 1, 3600] {
      let receipt = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(interval))
      XCTAssertTrue(receipt.satisfies(profileID: firstProfile, since: completedAt))
    }
  }

  func testFreshReceiptFromPreviousLoginCannotSuppressNewProfileFetch() {
    let previousLogin = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(60))
    XCTAssertFalse(previousLogin.satisfies(profileID: secondProfile, since: completedAt))
  }

  func testTwoAccountReceiptsCannotSatisfyEachOthersFetch() {
    let first = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(1))
    let second = ClaudeCodeUsageReceipt(profileID: secondProfile, fetchedAt: completedAt.addingTimeInterval(2))
    XCTAssertTrue(first.satisfies(profileID: firstProfile, since: completedAt))
    XCTAssertTrue(second.satisfies(profileID: secondProfile, since: completedAt))
    XCTAssertFalse(first.satisfies(profileID: secondProfile, since: completedAt))
    XCTAssertFalse(second.satisfies(profileID: firstProfile, since: completedAt))
  }

  func testUnresolvedManagedRenewalBlocksRemovalUntilAdoptionClearsMarker() throws {
    let identity = ClaudeCodeIdentity(accountID: firstProfile, organizationID: secondProfile)
    var pending = ClaudeCodeProfile.storedCredentials(
      token: ClaudeCodeCredentials(accessToken: "old", expiresAt: completedAt.addingTimeInterval(-1)),
      identity: identity, profileID: firstProfile)
    pending[CredentialField.anthropicRenewalPending] = "true"
    XCTAssertTrue(ClaudeCodeProfile.isRemovalBlocked(for: pending))

    let adopted = try XCTUnwrap(ClaudeCodeProfile.adoption(
      for: pending,
      credentials: ClaudeCodeCredentials(accessToken: "new", expiresAt: completedAt.addingTimeInterval(3600)),
      identity: identity, profileID: firstProfile, now: completedAt))
    XCTAssertFalse(ClaudeCodeProfile.isRemovalBlocked(for: adopted))
  }

  func testManagedProfileWithoutPendingMarkerAndManualTokenDoNotBlockRemoval() {
    let identity = ClaudeCodeIdentity(accountID: firstProfile, organizationID: secondProfile)
    let managed = ClaudeCodeProfile.storedCredentials(
      token: ClaudeCodeCredentials(accessToken: "token", expiresAt: completedAt),
      identity: identity, profileID: firstProfile)
    XCTAssertFalse(ClaudeCodeProfile.isRemovalBlocked(for: managed))
    XCTAssertFalse(ClaudeCodeProfile.isRemovalBlocked(for: [CredentialField.anthropicAccessToken: "manual"]))
    // A stray marker cannot turn a manual token into a managed profile.
    XCTAssertFalse(ClaudeCodeProfile.isRemovalBlocked(for: [
      CredentialField.anthropicAccessToken: "manual", CredentialField.anthropicRenewalPending: "true"
    ]))
  }
}
