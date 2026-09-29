import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeRenewalTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let profileID = UUID()
  private let identity = ClaudeCodeIdentity(accountID: UUID(), organizationID: UUID())
  private let material = ClaudeCodeRenewalMaterial(refreshToken: "cli-owned", scopes: ["user:profile"])

  private func login(_ token: String, remaining: TimeInterval, identity: ClaudeCodeIdentity? = nil,
                     hasRenewal: Bool = true) -> ClaudeCodeLogin {
    ClaudeCodeLogin(credentials: ClaudeCodeCredentials(accessToken: token, expiresAt: now.addingTimeInterval(remaining)),
                    identity: identity ?? self.identity, renewal: hasRenewal ? material : nil)
  }

  private func stored(_ token: String = "old", remaining: TimeInterval = 60, pending: Bool = false) -> [String: String] {
    var result = ClaudeCodeProfile.storedCredentials(
      token: login(token, remaining: remaining).credentials, identity: identity, profileID: profileID)
    if pending { result[CredentialField.anthropicRenewalPending] = "true" }
    return result
  }

  private func prepare(_ stored: [String: String], fixture: RenewalFixture, force: Bool = false) async throws -> [String: String] {
    try await ClaudeCodeRenewal.prepare(
      stored: stored, force: force, now: now,
      read: { await fixture.read() }, persist: { try await fixture.persist($0) },
      renew: { await fixture.renew($0) })
  }

  func testPersistsPendingBeforeSpawnThenAdoptsCompletedRenewal() async throws {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60), login("new", remaining: 3600)])
    let result = try await prepare(stored(), fixture: fixture)
    XCTAssertEqual(result[CredentialField.anthropicAccessToken], "new")
    XCTAssertNil(result[CredentialField.anthropicRenewalPending])
    let events = await fixture.events
    XCTAssertEqual(events, ["read", "persist-pending", "renew", "read", "persist-ready"])
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 2)
    XCTAssertEqual(saved[0][CredentialField.anthropicRenewalPending], "true")
    XCTAssertFalse(saved.flatMap(\.values).contains("cli-owned"))
  }

  func testPersistenceFailureDoesNotSpawnCLI() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)], failPersistence: true)
    do {
      _ = try await prepare(stored(), fixture: fixture)
      XCTFail("Persistence failure must prevent rotation")
    } catch {
      XCTAssertTrue(error is RenewalFixture.Failure)
    }
    let events = await fixture.events
    XCTAssertEqual(events, ["read", "persist-pending"])
  }

  func testTimeoutRetainsPendingMarkerAndDoesNotRereadWhileChildRuns() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)], renewalCompleted: false)
    do {
      _ = try await prepare(stored(), fixture: fixture)
      XCTFail("Running renewal must not be reported as complete")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .inProgress)
    }
    let events = await fixture.events
    XCTAssertEqual(events, ["read", "persist-pending", "renew"])
    let saved = await fixture.saved
    XCTAssertEqual(saved.last?[CredentialField.anthropicRenewalPending], "true")
  }

  func testRestartWithPendingAndUnchangedTokenDoesNotReplayRefresh() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 3600)])
    do {
      _ = try await prepare(stored(remaining: 3600, pending: true), fixture: fixture)
      XCTFail("An interrupted rotation requires a fresh saved token or reconnect")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .reconnectRequired)
    }
    let events = await fixture.events
    XCTAssertEqual(events, ["read"])
  }

  func testRestartAdoptsCompletedRotationWithoutRunningAgain() async throws {
    let fixture = RenewalFixture(logins: [login("new", remaining: 3600)])
    let result = try await prepare(stored(pending: true), fixture: fixture, force: true)
    XCTAssertEqual(result[CredentialField.anthropicAccessToken], "new")
    XCTAssertNil(result[CredentialField.anthropicRenewalPending])
    let events = await fixture.events
    XCTAssertEqual(events, ["read", "persist-ready"])
  }

  func testWrongIdentityCannotPersistOrSpawn() async {
    let other = ClaudeCodeIdentity(accountID: UUID(), organizationID: identity.organizationID)
    let fixture = RenewalFixture(logins: [login("other", remaining: 3600, identity: other)])
    do {
      _ = try await prepare(stored(), fixture: fixture)
      XCTFail("Another account cannot renew this profile")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .identityMismatch)
    }
    let events = await fixture.events
    XCTAssertEqual(events, ["read"])
  }

  func testCompletedChildMustHaveSavedFreshChangedTokenForSameIdentity() async {
    for next in [login("old", remaining: 3600), login("new", remaining: 300),
                 login("new", remaining: 3600, identity: ClaudeCodeIdentity(accountID: UUID(), organizationID: UUID()))] {
      let fixture = RenewalFixture(logins: [login("old", remaining: 60), next])
      do {
        _ = try await prepare(stored(), fixture: fixture)
        XCTFail("Child exit alone must not clear the pending marker")
      } catch {
        XCTAssertTrue(error is ClaudeCodeRenewalError)
      }
      let saved = await fixture.saved
      XCTAssertEqual(saved.count, 1)
      XCTAssertEqual(saved[0][CredentialField.anthropicRenewalPending], "true")
    }
  }

  func testFreshTokenDoesNotSpawnUnlessForced() async throws {
    let fresh = login("old", remaining: 3600)
    let fixture = RenewalFixture(logins: [fresh])
    let result = try await prepare(stored(remaining: 3600), fixture: fixture)
    XCTAssertEqual(result, stored(remaining: 3600))
    let events = await fixture.events
    XCTAssertEqual(events, ["read"])

    let forced = RenewalFixture(logins: [fresh, login("new", remaining: 7200)])
    _ = try await prepare(stored(remaining: 3600), fixture: forced, force: true)
    let forcedEvents = await forced.events
    XCTAssertTrue(forcedEvents.contains("renew"))
  }

  func testMissingRenewalMaterialRequiresReconnectWithoutPersisting() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60, hasRenewal: false)])
    do {
      _ = try await prepare(stored(), fixture: fixture)
      XCTFail("No rotation is possible without a CLI-owned refresh token")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .missingRenewalMaterial)
    }
    let events = await fixture.events
    XCTAssertEqual(events, ["read"])
  }

  func testStaleDifferentCLITokenCannotReplayItsRefreshGrant() async {
    let fixture = RenewalFixture(logins: [login("stale", remaining: -3600)])
    do {
      _ = try await prepare(stored(), fixture: fixture)
      XCTFail("A stale credential store cannot rotate over the currently saved token")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .reconnectRequired)
    }
    let events = await fixture.events
    XCTAssertEqual(events, ["read"])
  }

  func testSubprocessErrorLeavesDurablePendingMarker() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    do {
      _ = try await ClaudeCodeRenewal.prepare(
        stored: stored(), now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in throw RenewalFixture.Failure.subprocess })
      XCTFail("Subprocess failure must propagate")
    } catch {
      XCTAssertTrue(error is RenewalFixture.Failure)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.last?[CredentialField.anthropicRenewalPending], "true")
  }

  func testMissingExecutableRestoresCredentialsWithoutPendingMarker() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    let runner = ClaudeCodeProcess()
    let original = stored()
    let directory = FileManager.default.temporaryDirectory
    do {
      _ = try await ClaudeCodeRenewal.prepare(
        stored: original, now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in
          _ = try await runner.run(
            executable: directory.appendingPathComponent(UUID().uuidString), arguments: [], environment: [:],
            workingDirectory: directory, timeout: 5)
          return true
        })
      XCTFail("A missing executable cannot start renewal")
    } catch {
      XCTAssertFalse(error is ClaudeCodeProcess.StartFailure)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 2)
    XCTAssertEqual(saved.last, original)
  }

  func testCancellationBeforeLaunchRestoresCredentialsWithoutPendingMarker() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    let runner = ClaudeCodeProcess()
    let original = stored()
    let now = self.now
    let directory = FileManager.default.temporaryDirectory
    let operation = Task {
      try await ClaudeCodeRenewal.prepare(
        stored: original, now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
          _ = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], environment: [:],
            workingDirectory: directory, timeout: 5)
          return true
        })
    }
    do {
      _ = try await operation.value
      XCTFail("Cancellation before launch must propagate")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 2)
    XCTAssertEqual(saved.last, original)
  }

  func testPreparationFailureRestoresCredentialsAndPreservesItsError() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    let original = stored()
    do {
      _ = try await ClaudeCodeRenewal.prepare(
        stored: original, now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in throw ClaudeCodeProcess.StartFailure(RenewalFixture.Failure.subprocess) })
      XCTFail("Preparation failure must propagate")
    } catch {
      XCTAssertEqual(error as? RenewalFixture.Failure, .subprocess)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 2)
    XCTAssertEqual(saved.last, original)
  }

  func testFailedRollbackKeepsPendingMarkerAndReportsPersistenceFailure() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)], failRollback: true)
    do {
      _ = try await ClaudeCodeRenewal.prepare(
        stored: stored(), now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in throw ClaudeCodeProcess.StartFailure(RenewalFixture.Failure.subprocess) })
      XCTFail("Rollback failure must propagate")
    } catch {
      XCTAssertEqual(error as? RenewalFixture.Failure, .persistence)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.last?[CredentialField.anthropicRenewalPending], "true")
    let events = await fixture.events
    XCTAssertEqual(events, ["read", "persist-pending", "persist-ready"])
  }

  func testNonzeroChildExitLeavesDurablePendingMarker() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    let runner = ClaudeCodeProcess()
    let directory = FileManager.default.temporaryDirectory
    do {
      _ = try await ClaudeCodeRenewal.prepare(
        stored: stored(), now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in
          let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"], environment: [:],
            workingDirectory: directory, timeout: 5)
          XCTAssertEqual(result, .completed(status: 7))
          throw ClaudeCodeRenewalError.renewalIncomplete
        })
      XCTFail("An exited child may already have consumed its grant")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .renewalIncomplete)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.last?[CredentialField.anthropicRenewalPending], "true")
  }

  func testCancellationWithoutLaunchProofLeavesDurablePendingMarker() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    do {
      _ = try await ClaudeCodeRenewal.prepare(
        stored: stored(), now: now,
        read: { await fixture.read() }, persist: { try await fixture.persist($0) },
        renew: { _ in throw CancellationError() })
      XCTFail("Cancellation alone does not prove that a child never started")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let saved = await fixture.saved
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.last?[CredentialField.anthropicRenewalPending], "true")
  }

  func testUnmanagedAccountIsRejectedBeforeReadingProfile() async {
    let fixture = RenewalFixture(logins: [login("old", remaining: 60)])
    do {
      _ = try await prepare([CredentialField.anthropicAccessToken: "manual"], fixture: fixture)
      XCTFail("Manual accounts do not have a profile to renew")
    } catch {
      XCTAssertEqual(error as? ClaudeCodeRenewalError, .missingProfile)
    }
    let events = await fixture.events
    XCTAssertTrue(events.isEmpty)
  }
}

private actor RenewalFixture {
  enum Failure: Error, Equatable { case persistence, subprocess }
  private var logins: [ClaudeCodeLogin]
  private let failPersistence: Bool
  private let failRollback: Bool
  private let renewalCompleted: Bool
  private(set) var events: [String] = []
  private(set) var saved: [[String: String]] = []

  init(logins: [ClaudeCodeLogin], failPersistence: Bool = false, renewalCompleted: Bool = true,
       failRollback: Bool = false) {
    self.logins = logins
    self.failPersistence = failPersistence
    self.failRollback = failRollback
    self.renewalCompleted = renewalCompleted
  }

  func read() -> ClaudeCodeLogin {
    events.append("read")
    return logins.count == 1 ? logins[0] : logins.removeFirst()
  }

  func persist(_ credentials: [String: String]) throws {
    events.append(credentials[CredentialField.anthropicRenewalPending] == nil ? "persist-ready" : "persist-pending")
    if failPersistence || (failRollback && !saved.isEmpty) { throw Failure.persistence }
    saved.append(credentials)
  }

  func renew(_ material: ClaudeCodeRenewalMaterial) -> Bool {
    events.append("renew")
    return renewalCompleted
  }
}
