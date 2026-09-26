import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeProfileRetirementTests: XCTestCase {
  private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  private func managed(pending: Bool = false) -> [String: String] {
    var credentials = [
      CredentialField.anthropicProfileID: profileID.uuidString,
      CredentialField.anthropicCredentialSource: ClaudeCodeCredentialSource.managedProfile.rawValue
    ]
    if pending { credentials[CredentialField.anthropicRenewalPending] = "true" }
    return credentials
  }

  func testPendingRenewalRemovesAccountButNeverAttemptsProfileDeletion() throws {
    let fixture = RemovalFixture(failure: .deletion)
    let result = try fixture.remove(stored: managed(pending: true))

    XCTAssertEqual(result, .retained)
    XCTAssertEqual(fixture.events, [.retain(profileID), .removeAccount])
    XCTAssertTrue(fixture.retentionSaved)
    XCTAssertFalse(fixture.accountExists)
    XCTAssertTrue(fixture.profileExists)
  }

  func testAnyReportedRefreshLockRetainsProfileWithoutAnAgeBasedBypass() throws {
    // Both fresh and stale locks are reported as present. Only the service can
    // establish whether a process is still writing; this policy never guesses.
    for pending in [false, true] {
      let fixture = RemovalFixture(failure: .deletion)
      let result = try fixture.remove(stored: managed(pending: pending), refreshLocked: true)
      XCTAssertEqual(result, .retained)
      XCTAssertEqual(fixture.events, [.retain(profileID), .removeAccount])
      XCTAssertTrue(fixture.profileExists)
    }
  }

  func testCleanProfileIsDeletedOnlyAfterRecoveryRecordAndAccountRemovalAreSaved() throws {
    let fixture = RemovalFixture()
    let result = try fixture.remove(stored: managed())

    XCTAssertEqual(result, .removed)
    XCTAssertEqual(fixture.events, [.retain(profileID), .removeAccount, .deleteProfile(profileID)])
    XCTAssertFalse(fixture.accountExists)
    XCTAssertFalse(fixture.profileExists)
  }

  func testRetentionWriteFailureLeavesAccountAndProfileUntouched() {
    let fixture = RemovalFixture(failure: .retention)
    XCTAssertThrowsError(try fixture.remove(stored: managed())) {
      XCTAssertEqual($0 as? RemovalFixture.Failure, .retention)
    }
    XCTAssertEqual(fixture.events, [.retain(profileID)])
    XCTAssertTrue(fixture.accountExists)
    XCTAssertTrue(fixture.profileExists)
  }

  func testAccountSaveFailureLeavesRecoveryRecordAndActiveProfileUndeleted() {
    let fixture = RemovalFixture(failure: .settings)
    XCTAssertThrowsError(try fixture.remove(stored: managed())) {
      XCTAssertEqual($0 as? RemovalFixture.Failure, .settings)
    }
    XCTAssertEqual(fixture.events, [.retain(profileID), .removeAccount])
    XCTAssertTrue(fixture.retentionSaved)
    XCTAssertTrue(fixture.accountExists)
    XCTAssertTrue(fixture.profileExists)
  }

  func testCleanupFailureReturnsRetainedAfterAccountWasDurablyRemoved() throws {
    let fixture = RemovalFixture(failure: .deletion)
    let result = try fixture.remove(stored: managed())

    XCTAssertEqual(result, .retained)
    XCTAssertEqual(fixture.events, [.retain(profileID), .removeAccount, .deleteProfile(profileID)])
    XCTAssertTrue(fixture.retentionSaved)
    XCTAssertFalse(fixture.accountExists)
    XCTAssertTrue(fixture.profileExists)
  }

  func testManualAccountRemovalNeverUsesProfileRetentionOrDeletion() throws {
    let fixture = RemovalFixture(failure: .retention)
    let result = try fixture.remove(stored: [CredentialField.anthropicAccessToken: "manual"], refreshLocked: true)

    XCTAssertEqual(result, .removed)
    XCTAssertEqual(fixture.events, [.removeAccount])
    XCTAssertFalse(fixture.retentionSaved)
    XCTAssertFalse(fixture.accountExists)
  }

  func testManualAccountSaveFailureStillPropagates() {
    let fixture = RemovalFixture(failure: .settings)
    XCTAssertThrowsError(try fixture.remove(stored: [CredentialField.anthropicAccessToken: "manual"])) {
      XCTAssertEqual($0 as? RemovalFixture.Failure, .settings)
    }
    XCTAssertEqual(fixture.events, [.removeAccount])
    XCTAssertTrue(fixture.accountExists)
  }
}

private final class RemovalFixture {
  enum Failure: Error { case retention, settings, deletion }
  enum Event: Equatable { case retain(UUID), removeAccount, deleteProfile(UUID) }
  private let failure: Failure?
  private(set) var events: [Event] = []
  private(set) var retentionSaved = false
  private(set) var accountExists = true
  private(set) var profileExists = true

  init(failure: Failure? = nil) { self.failure = failure }

  func remove(stored: [String: String], refreshLocked: Bool = false) throws -> ClaudeCodeProfileRetirement.Outcome {
    try ClaudeCodeProfileRetirement.commit(
      stored: stored, refreshLocked: refreshLocked,
      retain: { profile in
        self.events.append(.retain(profile.id))
        if self.failure == .retention { throw Failure.retention }
        self.retentionSaved = true
      },
      commitAccountChange: {
        self.events.append(.removeAccount)
        if self.failure == .settings { throw Failure.settings }
        self.accountExists = false
      },
      deleteProfile: { profile in
        self.events.append(.deleteProfile(profile.id))
        if self.failure == .deletion { throw Failure.deletion }
        self.profileExists = false
      })
  }
}
