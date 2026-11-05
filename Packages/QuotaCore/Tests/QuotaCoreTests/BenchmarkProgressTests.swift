import XCTest
@testable import QuotaCore

final class BenchmarkProgressTests: XCTestCase {

  // MARK: - Fixtures

  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func fixturePlan(
    candidates: Int = 2,
    repetitions: Int = 3,
    judges: Int = 2
  ) -> BenchmarkPlan {
    let candidates = (0..<candidates).map {
      BenchmarkCandidate(id: UUID(), name: "Agent \($0)", command: BenchmarkCommand(executable: "/bin/echo"))
    }
    let judges = (0..<judges).map {
      BenchmarkJudge(id: UUID(), name: "Judge \($0)", command: BenchmarkCommand(executable: "/bin/echo"))
    }
    return BenchmarkPlan(
      taskPrompt: "Fix the bug.",
      rubric: "Pass tests.",
      repositoryPath: "/tmp/repo",
      repetitions: repetitions,
      candidates: candidates,
      judges: judges
    )
  }

  private func fixtureReport(plan: BenchmarkPlan, runs: [BenchmarkRun] = []) -> BenchmarkReport {
    BenchmarkReport(
      startedAt: start,
      baselineCommit: "abc123",
      plan: plan,
      runs: runs
    )
  }

  // MARK: - Partial report: 2 candidates × 3 reps = 6 total

  func testPartialReportWithCompletedAndFailedTrials() {
    let plan = fixturePlan(candidates: 2, repetitions: 3, judges: 2)
    let candidateA = plan.candidates[0].id
    let judgeA = plan.judges[0].id

    // One completed trial with 1 of 2 judges evaluated.
    let completedRun = BenchmarkRun(
      candidateID: candidateA,
      repetition: 0,
      startedAt: start,
      outcome: .completed,
      evaluations: [
        BenchmarkEvaluation(judgeID: judgeA, accepted: true, score: 8, explanation: "Good")
      ]
    )

    // One failed trial.
    let failedRun = BenchmarkRun(
      candidateID: candidateA,
      repetition: 1,
      startedAt: start,
      outcome: .failed,
      evaluations: []
    )

    let report = fixtureReport(plan: plan, runs: [completedRun, failedRun])
    let progress = BenchmarkProgress(report: report, phase: .runningTrial)

    // 2 attempts completed out of 6 total (2 candidates × 3 reps).
    XCTAssertEqual(progress.completedAttempts, 2)
    XCTAssertEqual(progress.totalAttempts, 6)
    XCTAssertEqual(progress.attemptFraction, 1.0 / 3.0, accuracy: 1e-9)

    // 1 evaluation completed; only the completed run is eligible for judging (1 × 2 judges = 2).
    XCTAssertEqual(progress.completedEvaluations, 1)
    XCTAssertEqual(progress.totalEvaluations, 2)
    XCTAssertEqual(progress.evaluationFraction, 0.5, accuracy: 1e-9)

    XCTAssertEqual(progress.startedAt, start)
    XCTAssertFalse(progress.isTerminal)
  }

  // MARK: - Empty report

  func testEmptyReportHasZeroFractions() {
    let plan = fixturePlan(candidates: 2, repetitions: 3, judges: 2)
    let report = fixtureReport(plan: plan)
    let progress = BenchmarkProgress(report: report, phase: .preparing)

    XCTAssertEqual(progress.completedAttempts, 0)
    XCTAssertEqual(progress.totalAttempts, 6)
    XCTAssertEqual(progress.attemptFraction, 0)

    XCTAssertEqual(progress.completedEvaluations, 0)
    XCTAssertEqual(progress.totalEvaluations, 0)
    XCTAssertEqual(progress.evaluationFraction, 0)

    XCTAssertEqual(progress.startedAt, start)
    XCTAssertFalse(progress.isTerminal)
  }

  // MARK: - All failed trials: zero eligible judges

  func testAllFailedTrialsHaveZeroEligibleEvaluations() {
    let plan = fixturePlan(candidates: 2, repetitions: 3, judges: 2)
    let candidateA = plan.candidates[0].id

    let run1 = BenchmarkRun(candidateID: candidateA, repetition: 0, startedAt: start, outcome: .failed)
    let run2 = BenchmarkRun(candidateID: candidateA, repetition: 1, startedAt: start, outcome: .timedOut)
    let report = fixtureReport(plan: plan, runs: [run1, run2])
    let progress = BenchmarkProgress(report: report, phase: .runningTrial)

    XCTAssertEqual(progress.completedAttempts, 2)
    XCTAssertEqual(progress.totalAttempts, 6)

    // No completed runs → no eligible evaluations.
    XCTAssertEqual(progress.completedEvaluations, 0)
    XCTAssertEqual(progress.totalEvaluations, 0)
    XCTAssertEqual(progress.evaluationFraction, 0)
  }

  // MARK: - Terminal phases

  func testCompletedPhaseIsTerminal() {
    let plan = fixturePlan(candidates: 1, repetitions: 1, judges: 2)
    let report = fixtureReport(plan: plan)
    let progress = BenchmarkProgress(report: report, phase: .completed)
    XCTAssertTrue(progress.isTerminal)
  }

  func testCancelledPhaseIsTerminal() {
    let plan = fixturePlan(candidates: 1, repetitions: 1, judges: 2)
    let report = fixtureReport(plan: plan)
    let progress = BenchmarkProgress(report: report, phase: .cancelled)
    XCTAssertTrue(progress.isTerminal)
  }

  func testNonTerminalPhases() {
    let plan = fixturePlan(candidates: 1, repetitions: 1, judges: 2)
    let report = fixtureReport(plan: plan)

    for phase in [
      BenchmarkProgress.Phase.preparing,
      BenchmarkProgress.Phase.runningTrial,
      BenchmarkProgress.Phase.waitingForQuota,
      BenchmarkProgress.Phase.checkingAcceptance,
      BenchmarkProgress.Phase.evaluating
    ] as [BenchmarkProgress.Phase] {
      let progress = BenchmarkProgress(report: report, phase: phase)
      XCTAssertFalse(progress.isTerminal, "\(phase.rawValue) should not be terminal")
    }
  }

  // MARK: - Cancelled preserves counts

  func testCancelledPreservesCompletedCounts() {
    let plan = fixturePlan(candidates: 2, repetitions: 3, judges: 2)
    let candidateA = plan.candidates[0].id
    let judgeA = plan.judges[0].id

    let completedRun = BenchmarkRun(
      candidateID: candidateA,
      repetition: 0,
      startedAt: start,
      outcome: .completed,
      evaluations: [
        BenchmarkEvaluation(judgeID: judgeA, accepted: true, score: 7, explanation: "OK")
      ]
    )
    let failedRun = BenchmarkRun(candidateID: candidateA, repetition: 1, startedAt: start, outcome: .failed)
    let report = fixtureReport(plan: plan, runs: [completedRun, failedRun])

    let progress = BenchmarkProgress(report: report, phase: .cancelled)

    XCTAssertEqual(progress.completedAttempts, 2)
    XCTAssertEqual(progress.totalAttempts, 6)
    XCTAssertEqual(progress.completedEvaluations, 1)
    XCTAssertEqual(progress.totalEvaluations, 2)
    XCTAssertTrue(progress.isTerminal)
  }

  // MARK: - Overflow defense for bad plan values

  func testNoOverflowForBadPlanValues() {
    // Simulate a malformed plan with extreme values that would overflow.
    var plan = fixturePlan(candidates: 2, repetitions: 3, judges: 2)
    plan.repetitions = Int.max

    let report = fixtureReport(plan: plan)
    let progress = BenchmarkProgress(report: report, phase: .preparing)

    // Should not crash; clamped to known valid max.
    XCTAssertEqual(progress.totalAttempts, 40)
    // Fraction should still be bounded.
    XCTAssertEqual(progress.attemptFraction, 0)
    XCTAssertGreaterThanOrEqual(progress.attemptFraction, 0)
    XCTAssertLessThanOrEqual(progress.attemptFraction, 1)
  }

  func testZeroCandidatesHaveNoPlannedAttempts() {
    let plan = fixturePlan(candidates: 0, repetitions: 3, judges: 2)
    let report = fixtureReport(plan: plan)
    let progress = BenchmarkProgress(report: report, phase: .preparing)

    XCTAssertEqual(progress.totalAttempts, 0)
    XCTAssertEqual(progress.attemptFraction, 0)
  }

  // MARK: - Current context tracking

  func testCurrentCandidateAndJudgeTracking() {
    let plan = fixturePlan(candidates: 2, repetitions: 3, judges: 2)
    let candidateA = plan.candidates[0].id
    let judgeA = plan.judges[0].id
    let report = fixtureReport(plan: plan)

    let progress = BenchmarkProgress(
      report: report,
      phase: .evaluating,
      currentCandidateID: candidateA,
      currentRepetition: 1,
      currentJudgeID: judgeA
    )

    XCTAssertEqual(progress.currentCandidateID, candidateA)
    XCTAssertEqual(progress.currentRepetition, 1)
    XCTAssertEqual(progress.currentJudgeID, judgeA)
  }

  // MARK: - Fraction bounds

  func testFractionsNeverExceedOne() {
    let plan = fixturePlan(candidates: 1, repetitions: 1, judges: 1)
    let candidateA = plan.candidates[0].id
    let judgeA = plan.judges[0].id

    let completedRun = BenchmarkRun(
      candidateID: candidateA,
      repetition: 0,
      startedAt: start,
      outcome: .completed,
      evaluations: [
        BenchmarkEvaluation(judgeID: judgeA, accepted: true, score: 9, explanation: "Great")
      ]
    )
    let report = fixtureReport(plan: plan, runs: [completedRun])
    let progress = BenchmarkProgress(report: report, phase: .evaluating)

    XCTAssertEqual(progress.attemptFraction, 1, accuracy: 1e-9)
    XCTAssertEqual(progress.evaluationFraction, 1, accuracy: 1e-9)
    XCTAssertLessThanOrEqual(progress.attemptFraction, 1)
    XCTAssertLessThanOrEqual(progress.evaluationFraction, 1)
  }

  // MARK: - Equatable

  func testEquatableWithSameState() {
    let plan = fixturePlan(candidates: 1, repetitions: 2, judges: 2)
    let report = fixtureReport(plan: plan)
    let p1 = BenchmarkProgress(report: report, phase: .preparing)
    let p2 = BenchmarkProgress(report: report, phase: .preparing)
    XCTAssertEqual(p1, p2)
  }

  func testEquatableWithDifferentPhase() {
    let plan = fixturePlan(candidates: 1, repetitions: 2, judges: 2)
    let report = fixtureReport(plan: plan)
    let p1 = BenchmarkProgress(report: report, phase: .preparing)
    let p2 = BenchmarkProgress(report: report, phase: .runningTrial)
    XCTAssertNotEqual(p1, p2)
  }
}
