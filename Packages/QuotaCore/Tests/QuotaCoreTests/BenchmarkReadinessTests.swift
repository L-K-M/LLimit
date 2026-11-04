import XCTest
@testable import QuotaCore

final class BenchmarkReadinessTests: XCTestCase {
  private func plan() -> BenchmarkPlan {
    let command = BenchmarkCommand(executable: "/usr/bin/true")
    return BenchmarkPlan(taskPrompt: "Implement the requested change.", rubric: "Pass the acceptance check.", repositoryPath: "/tmp/repository",
      candidates: [BenchmarkCandidate(name: "Candidate", command: command)],
      judges: [BenchmarkJudge(name: "Codex judge", command: command), BenchmarkJudge(name: "Claude judge", command: command)])
  }

  func testNamesTheJudgeBlockingRunAndRecoversWhenItIsConfirmed() {
    let plan = plan()
    let blocked = BenchmarkReadiness(plan: plan, accountUseConfirmed: true, invalidEditorIDs: [plan.judges[0].id])
    XCTAssertFalse(blocked.isReady)
    XCTAssertEqual(blocked.reasons.count, 1)
    XCTAssertTrue(blocked.reasons[0].contains("Codex judge"))
    XCTAssertTrue(blocked.reasons[0].contains("model selection"))
    XCTAssertTrue(BenchmarkReadiness(plan: plan, accountUseConfirmed: true, invalidEditorIDs: []).isReady)
  }

  func testHistoryReplacementCannotBeBlockedByOldEditorIDs() {
    let old = plan()
    let loaded = plan()
    let staleIDs = Set([old.candidates[0].id, old.judges[0].id])
    XCTAssertTrue(BenchmarkReadiness(plan: loaded, accountUseConfirmed: true, invalidEditorIDs: staleIDs).isReady)
  }

  func testAccountConfirmationAndInvalidTaskHaveVisibleReasons() {
    var plan = plan()
    plan.taskPrompt = ""
    let blocked = BenchmarkReadiness(plan: plan, accountUseConfirmed: false, invalidEditorIDs: [])
    XCTAssertFalse(blocked.isReady)
    XCTAssertEqual(blocked.reasons.count, 2)
    XCTAssertTrue(blocked.reasons[0].contains("task"))
    XCTAssertTrue(blocked.reasons[1].contains("Confirm"))
  }

  func testCurrentAgentErrorsRemainBlockingAfterOtherEditorsDisappear() {
    let plan = plan()
    let blocked = BenchmarkReadiness(plan: plan, accountUseConfirmed: true, invalidEditorIDs: [plan.candidates[0].id, UUID()])
    XCTAssertEqual(blocked.reasons.count, 1)
    XCTAssertTrue(blocked.reasons[0].contains("Candidate"))
    XCTAssertFalse(blocked.isReady)
  }
}
