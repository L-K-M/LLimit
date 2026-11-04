import XCTest
@testable import QuotaCore

final class BenchmarkModelsTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func usage(_ metrics: [UsageMetric], after: Bool = false, account: String = "account", provider: QuotaProvider = .openAI) -> ProviderUsage {
    ProviderUsage(accountID: account, provider: provider, title: "Account", metrics: metrics,
                  fetchedAt: start.addingTimeInterval(after ? 20 : 0))
  }

  private func plan() -> BenchmarkPlan {
    BenchmarkPlan(taskPrompt: "Fix the supplied bug.", rubric: "Pass the acceptance tests without breaking existing behavior.",
                  repositoryPath: "/tmp/repository", candidates: [BenchmarkCandidate(name: "Candidate", command: BenchmarkCommand(executable: "/bin/echo"))],
                  judges: [BenchmarkJudge(name: "Judge A", command: BenchmarkCommand(executable: "/bin/echo")),
                           BenchmarkJudge(name: "Judge B", command: BenchmarkCommand(executable: "/bin/echo"))])
  }

  func testRawAmountsPreserveConsumptionBelowDisplayResolution() throws {
    let before = usage([UsageMetric(id: "tokens", label: "Tokens", remainingPercent: 100, remainingAmount: 1_000, totalAmount: 1_000)])
    let after = usage([UsageMetric(id: "tokens", label: "Tokens", remainingPercent: 100, remainingAmount: 999.25, totalAmount: 1_000)], after: true)
    let change = try XCTUnwrap(BenchmarkQuotaChange.changes(before: before, after: after).first)
    XCTAssertEqual(try XCTUnwrap(change.consumedAmount), 0.75, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(change.consumedPercentagePoints), 0.075, accuracy: 0.000001)
    XCTAssertNil(change.unavailableReason)
  }

  func testPercentageOnlyUnchangedReadingIsNotZeroCost() {
    let before = usage([UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70)])
    let after = usage([UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70)], after: true)
    let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
    XCTAssertNil(change.consumedAmount)
    XCTAssertNil(change.consumedPercentagePoints)
    XCTAssertTrue(change.unavailableReason?.contains("resolution") == true)
  }

  func testOverlappingQuotaWindowsRemainSeparate() {
    let before = usage([UsageMetric(id: "short", label: "5-hour", remainingPercent: 70), UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 90)])
    let after = usage([UsageMetric(id: "short", label: "5-hour", remainingPercent: 65), UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 88)], after: true)
    let changes = BenchmarkQuotaChange.changes(before: before, after: after)
    XCTAssertEqual(changes.map(\.metricID), ["short", "weekly"])
    XCTAssertEqual(changes.map(\.consumedPercentagePoints), [5, 2])
  }

  func testResetBoundaryRejectsEvenMonotonicallyLowerUsage() {
    let reset = start.addingTimeInterval(10)
    let before = usage([UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70, resetAt: reset)])
    let changedReset = usage([UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 60, resetAt: reset.addingTimeInterval(604_800))], after: true)
    let staleReset = usage([UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 60, resetAt: reset)], after: true)
    for after in [changedReset, staleReset] {
      let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
      XCTAssertNil(change.consumedPercentagePoints)
      XCTAssertTrue(change.unavailableReason?.contains("reset") == true)
    }
  }

  func testQuotaIncreaseIsNotNegativeConsumption() {
    for (beforeMetric, afterMetric) in [
      (UsageMetric(id: "a", label: "Credits", remainingAmount: 5), UsageMetric(id: "a", label: "Credits", remainingAmount: 6)),
      (UsageMetric(id: "a", label: "Weekly", remainingPercent: 50), UsageMetric(id: "a", label: "Weekly", remainingPercent: 60))
    ] {
      let change = BenchmarkQuotaChange.changes(before: usage([beforeMetric]), after: usage([afterMetric], after: true))[0]
      XCTAssertNil(change.consumedAmount)
      XCTAssertNil(change.consumedPercentagePoints)
      XCTAssertTrue(change.unavailableReason?.contains("increased") == true)
    }
  }

  func testChangedDenominatorOrEstimateIdentityIsUnavailable() {
    let original = UsageMetric(id: "a", label: "Credits", remainingAmount: 50, estimatedTotal: 100, estimateKeyHash: "original")
    for next in [
      UsageMetric(id: "a", label: "Credits", remainingAmount: 40, estimatedTotal: 200, estimateKeyHash: "original"),
      UsageMetric(id: "a", label: "Credits", remainingAmount: 40, estimatedTotal: 100, estimateKeyHash: "changed"),
      UsageMetric(id: "a", label: "Credits", remainingAmount: 40, totalAmount: 100, estimateKeyHash: "original")
    ] {
      let change = BenchmarkQuotaChange.changes(before: usage([original]), after: usage([next], after: true))[0]
      XCTAssertNil(change.consumedAmount)
      XCTAssertNil(change.consumedPercentagePoints)
    }
  }

  func testAccountIdentityAndFreshnessAreRequired() {
    let metric = UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70)
    let before = usage([metric])
    for after in [usage([metric]), usage([metric], after: true, account: "other"), usage([metric], after: true, provider: .anthropic)] {
      let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
      XCTAssertNil(change.consumedPercentagePoints)
      XCTAssertNotNil(change.unavailableReason)
    }
  }

  func testMissingMetricsAndMissingReadingsRemainVisible() {
    let before = usage([UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70)])
    for after in [nil, usage([], after: true)] {
      let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
      XCTAssertEqual(change.metricID, "weekly")
      XCTAssertNotNil(change.unavailableReason)
      XCTAssertNil(change.consumedPercentagePoints)
    }
    XCTAssertEqual(BenchmarkQuotaChange.changes(before: nil, after: nil).count, 1)
  }

  func testAmountOnlyQuotaDoesNotInventPercentage() {
    let before = usage([UsageMetric(id: "credits", label: "Credits", remainingAmount: 15)])
    let after = usage([UsageMetric(id: "credits", label: "Credits", remainingAmount: 11)], after: true)
    let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
    XCTAssertEqual(change.consumedAmount, 4)
    XCTAssertNil(change.consumedPercentagePoints)
  }

  func testInvalidAmountsAndUnlimitedQuotaAreUnavailable() {
    for metric in [
      UsageMetric(id: "credits", label: "Credits", remainingAmount: -1),
      UsageMetric(id: "credits", label: "Credits", remainingAmount: .infinity),
      UsageMetric(id: "credits", label: "Credits", remainingPercent: 80, isUnlimited: true)
    ] {
      var next = metric
      next.remainingAmount = 0
      let change = BenchmarkQuotaChange.changes(before: usage([metric]), after: usage([next], after: true))[0]
      XCTAssertNil(change.consumedAmount)
      XCTAssertNil(change.consumedPercentagePoints)
      XCTAssertNotNil(change.unavailableReason)
    }
  }

  func testOverflowingPercentageDoesNotLeakNonfiniteData() throws {
    let before = usage([UsageMetric(id: "credits", label: "Credits", remainingAmount: .greatestFiniteMagnitude, totalAmount: .leastNonzeroMagnitude)])
    let after = usage([UsageMetric(id: "credits", label: "Credits", remainingAmount: 0, totalAmount: .leastNonzeroMagnitude)], after: true)
    let change = BenchmarkQuotaChange.changes(before: before, after: after)[0]
    XCTAssertEqual(change.consumedAmount, .greatestFiniteMagnitude)
    XCTAssertNil(change.consumedPercentagePoints)
    XCTAssertNoThrow(try JSONEncoder().encode(change))
  }

  func testBothValidJudgesMustAgreeForAcceptance() {
    let spec = plan()
    func evaluation(_ index: Int, _ accepted: Bool, score: Double = 8) -> BenchmarkEvaluation {
      BenchmarkEvaluation(judgeID: spec.judges[index].id, accepted: accepted, score: score)
    }
    var run = BenchmarkRun(candidateID: spec.candidates[0].id, repetition: 1)
    XCTAssertNil(run.isAccepted)
    run.evaluations = [evaluation(0, true), evaluation(1, true)]
    XCTAssertEqual(run.isAccepted, true)
    run.evaluations[1] = evaluation(1, false)
    XCTAssertNil(run.isAccepted)
    run.evaluations = [evaluation(0, false), evaluation(1, false)]
    XCTAssertEqual(run.isAccepted, false)
    run.evaluations = [evaluation(0, true), evaluation(0, true)]
    XCTAssertNil(run.isAccepted)
    run.evaluations = [evaluation(0, true), evaluation(1, true, score: 99)]
    XCTAssertNil(run.isAccepted)
    run.acceptancePassed = false
    XCTAssertEqual(run.isAccepted, false)
    run.acceptancePassed = true
    run.outcome = .failed
    XCTAssertEqual(run.isAccepted, false)
  }

  func testSummaryIncludesFailedRunCostAndMedianSpread() throws {
    let spec = plan()
    let id = spec.candidates[0].id
    let votes = spec.judges.map { BenchmarkEvaluation(judgeID: $0.id, accepted: true, score: 8) }
    let runs = [
      BenchmarkRun(candidateID: id, repetition: 1, durationSeconds: 20, estimatedCost: 2, evaluations: votes),
      BenchmarkRun(candidateID: id, repetition: 2, durationSeconds: 10, outcome: .failed, estimatedCost: 1),
      BenchmarkRun(candidateID: id, repetition: 3, durationSeconds: 90, estimatedCost: 3, evaluations: votes)
    ]
    let summary = try XCTUnwrap(BenchmarkReport(baselineCommit: "abc", plan: spec, runs: runs).summaries.first)
    XCTAssertEqual(summary.attempts, 3)
    XCTAssertEqual(summary.acceptedCount, 2)
    XCTAssertEqual(summary.medianDurationSeconds, 20)
    XCTAssertEqual(summary.minDurationSeconds, 10)
    XCTAssertEqual(summary.maxDurationSeconds, 90)
    XCTAssertEqual(summary.estimatedTotalCost, 6)
    XCTAssertEqual(summary.estimatedCostPerAcceptedTask, 3)
    XCTAssertEqual(summary.meanQualityScore, 8)
  }

  func testIncompleteCostsNeverBecomePartialTotalOrFreeSuccess() {
    let spec = plan()
    let id = spec.candidates[0].id
    let votes = spec.judges.map { BenchmarkEvaluation(judgeID: $0.id, accepted: true, score: 8) }
    let runs = [BenchmarkRun(candidateID: id, repetition: 1, estimatedCost: 1, evaluations: votes),
                BenchmarkRun(candidateID: id, repetition: 2, estimatedCost: nil, evaluations: votes)]
    let summary = BenchmarkReport(baselineCommit: "abc", plan: spec, runs: runs).summaries[0]
    XCTAssertNil(summary.estimatedTotalCost)
    XCTAssertNil(summary.estimatedCostPerAcceptedTask)
    let empty = BenchmarkReport(baselineCommit: "abc", plan: spec).summaries[0]
    XCTAssertNil(empty.successRate)
    XCTAssertNil(empty.medianDurationSeconds)
    XCTAssertNil(empty.estimatedTotalCost)
  }

  func testValidationRejectsInvalidRunBudgetsAndCommandPaths() throws {
    XCTAssertNoThrow(try plan().validated())
    for repetitions in [0, 21] {
      var spec = plan()
      spec.repetitions = repetitions
      XCTAssertThrowsError(try spec.validated())
    }
    for timeout in [0, 86_401, .infinity, .nan] {
      var spec = plan()
      spec.timeoutSeconds = timeout
      XCTAssertThrowsError(try spec.validated())
    }
    var relative = plan()
    relative.candidates[0].command.executable = "echo"
    XCTAssertThrowsError(try relative.validated())
    var missingCriteria = plan()
    missingCriteria.rubric = " \n "
    XCTAssertThrowsError(try missingCriteria.validated())
    var judges = plan()
    judges.judges[1].id = judges.judges[0].id
    XCTAssertThrowsError(try judges.validated())
  }

  func testAllowanceCostRequiresExplicitMetricAndAccount() {
    var spec = plan()
    spec.candidates[0].allowanceCost = 20
    XCTAssertThrowsError(try spec.validated())
    spec.candidates[0].accountID = "account"
    XCTAssertThrowsError(try spec.validated())
    spec.candidates[0].quotaMetricID = "weekly"
    XCTAssertNoThrow(try spec.validated())
    spec.candidates[0].allowanceCost = -1
    XCTAssertThrowsError(try spec.validated())
  }

  func testReportStoreRoundTripPermissionsAndHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BenchmarkReportStore(directory: directory)
    XCTAssertTrue(try store.list().isEmpty)
    let first = BenchmarkReport(startedAt: start, baselineCommit: "abc", plan: plan())
    var second = BenchmarkReport(startedAt: start.addingTimeInterval(60), baselineCommit: "def", plan: plan())
    second.warnings = ["Quota measurement unavailable."]
    try store.save(first)
    try store.save(second)
    XCTAssertEqual(try store.load(id: first.id), first)
    XCTAssertEqual(try store.list().map(\.id), [second.id, first.id])
    XCTAssertNil(try store.load(id: UUID()))
    let file = directory.appendingPathComponent(first.id.uuidString.lowercased()).appendingPathExtension("json")
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testCorruptReportIsAnExplicitHistoryError() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json"))
    XCTAssertThrowsError(try BenchmarkReportStore(directory: directory).list())
  }

  func testReportFilenameIdentityMismatchIsRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BenchmarkReportStore(directory: directory)
    let report = BenchmarkReport(baselineCommit: "abc", plan: plan())
    try store.save(report)
    let original = directory.appendingPathComponent(report.id.uuidString.lowercased()).appendingPathExtension("json")
    let wrongID = UUID()
    let wrong = directory.appendingPathComponent(wrongID.uuidString.lowercased()).appendingPathExtension("json")
    try FileManager.default.moveItem(at: original, to: wrong)
    XCTAssertThrowsError(try store.load(id: wrongID))
    XCTAssertThrowsError(try store.list())
  }
}
