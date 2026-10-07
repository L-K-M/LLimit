import XCTest
@testable import QuotaCore

final class PendingEditsTests: XCTestCase {
  func testCommitConsumesSavedDraft() {
    var edits = PendingEdits<String>()
    edits.edit("venice.key", text: "key-b")

    var saved: [String] = []
    let outcome = edits.commit("venice.key") { key, text in
      saved.append("\(key)=\(text)")
      return .applied
    }

    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(saved, ["venice.key=key-b"])
    XCTAssertNil(edits.text(for: "venice.key"))
  }

  func testUnchangedAndMissingAccountConsumeDraft() {
    var edits = PendingEdits<String>()
    edits.edit("same", text: "key-a")
    edits.edit("removed", text: "key-b")

    edits.commit("same") { _, _ in .unchanged }
    edits.commit("removed") { _, _ in .accountMissing }

    XCTAssertNil(edits.text(for: "same"))
    XCTAssertNil(edits.text(for: "removed"))
  }

  func testRejectedDraftStaysWithReasonUntilRetrySucceeds() {
    var edits = PendingEdits<String>()
    edits.edit("venice.key", text: "key-b")

    let rejected = edits.commit("venice.key") { _, _ in .rejected(.previousUsageNotCleared) }

    XCTAssertEqual(rejected, .rejected(.previousUsageNotCleared))
    XCTAssertEqual(edits.text(for: "venice.key"), "key-b")
    XCTAssertEqual(edits.rejection(for: "venice.key"), .previousUsageNotCleared)

    var retried: [String] = []
    edits.commit("venice.key") { _, text in
      retried.append(text)
      return .applied
    }

    XCTAssertEqual(retried, ["key-b"])
    XCTAssertNil(edits.text(for: "venice.key"))
    XCTAssertNil(edits.rejection(for: "venice.key"))
  }

  func testEditingKeepsRejectionUntilNextCommit() {
    var edits = PendingEdits<String>()
    edits.edit("openai.token", text: "token-a")
    edits.commit("openai.token") { _, _ in .rejected(.signInInProgress) }

    edits.edit("openai.token", text: "token-b")

    XCTAssertEqual(edits.text(for: "openai.token"), "token-b")
    XCTAssertEqual(edits.rejection(for: "openai.token"), .signInInProgress)
  }

  func testCommitWithoutDraftDoesNotSave() {
    var edits = PendingEdits<String>()
    var calls = 0

    let outcome = edits.commit("untouched") { _, _ in
      calls += 1
      return .applied
    }

    XCTAssertNil(outcome)
    XCTAssertEqual(calls, 0)
  }

  func testCommitAllOffersEachDraftOnceAndKeepsRejected() {
    var edits = PendingEdits<String>()
    edits.edit("name", text: "Work")
    edits.edit("claude.token", text: "token")
    edits.edit("venice.key", text: "key-b")

    var offered: [String] = []
    edits.commitAll { key, _ in
      offered.append(key)
      return key == "claude.token" ? .rejected(.managedConnection) : .applied
    }

    XCTAssertEqual(offered.sorted(), ["claude.token", "name", "venice.key"])
    XCTAssertNil(edits.text(for: "name"))
    XCTAssertNil(edits.text(for: "venice.key"))
    XCTAssertEqual(edits.text(for: "claude.token"), "token")
    XCTAssertEqual(edits.rejection(for: "claude.token"), .managedConnection)
  }

  func testDiscardDropsOnlyMatchingDraftsAndTheirReasons() {
    var edits = PendingEdits<String>()
    edits.edit("a.name", text: "Work")
    edits.edit("a.key", text: "key-b")
    edits.edit("b.key", text: "key-c")
    edits.commit("a.key") { _, _ in .rejected(.settingsUnreadable) }

    edits.discard { $0 == "a.key" }

    XCTAssertNil(edits.text(for: "a.key"))
    XCTAssertNil(edits.rejection(for: "a.key"))
    XCTAssertEqual(edits.text(for: "a.name"), "Work")
    XCTAssertEqual(edits.text(for: "b.key"), "key-c")
  }

  func testOnlyRejectionKeepsDraft() {
    XCTAssertTrue(AccountEditOutcome.applied.consumesDraft)
    XCTAssertTrue(AccountEditOutcome.unchanged.consumesDraft)
    XCTAssertTrue(AccountEditOutcome.accountMissing.consumesDraft)
    XCTAssertFalse(AccountEditOutcome.rejected(.managedConnection).consumesDraft)
  }
}
