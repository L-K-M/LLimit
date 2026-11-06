import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkCostCoverageTests: XCTestCase {
  func testKnownSubtotalDoesNotPriceUnknownAttempts() {
    let candidate = BenchmarkCandidate(name: "Fixture", command: BenchmarkCommand(executable: "/bin/true"))
    let runs = [0.58, 0.29, nil].map { BenchmarkRun(candidateID: candidate.id, repetition: 1, estimatedCost: $0) }
    let coverage = BenchmarkCostCoverage(runs: runs)
    XCTAssertEqual(coverage.knownCost ?? -1, 0.87, accuracy: 0.000_001)
    XCTAssertEqual(coverage.pricedAttempts, 2)
    XCTAssertEqual(coverage.totalAttempts, 3)
    XCTAssertFalse(coverage.isComplete)
    let plan = BenchmarkPlan(taskPrompt: "Task", rubric: "Rubric", repositoryPath: "/tmp", candidates: [candidate], judges: [])
    XCTAssertNil(BenchmarkReport(baselineCommit: "fixture", plan: plan, runs: runs).summaries[0].estimatedTotalCost)
  }

  func testKnownZeroIsDistinctFromUnknownOrInvalidPrices() {
    let id = UUID()
    let zero = BenchmarkCostCoverage(runs: [BenchmarkRun(candidateID: id, repetition: 1, estimatedCost: 0)])
    XCTAssertEqual(zero.knownCost, 0)
    XCTAssertTrue(zero.isComplete)
    let unknown = BenchmarkCostCoverage(runs: [nil, Double.nan, Double.infinity, -1].map {
      BenchmarkRun(candidateID: id, repetition: 1, estimatedCost: $0)
    })
    XCTAssertNil(unknown.knownCost)
    XCTAssertEqual(unknown.pricedAttempts, 0)
    XCTAssertFalse(unknown.isComplete)
  }

  func testUnavailableSelectedWindowPointsOutMeasuredAlternativeWithoutSubstituting() {
    let candidate = BenchmarkCandidate(name: "Fixture", command: BenchmarkCommand(executable: "/bin/true"),
      accountID: "account", quotaMetricID: "vibe")
    let run = BenchmarkRun(candidateID: candidate.id, repetition: 1, quotaChanges: [
      BenchmarkQuotaChange(metricID: "vibe", label: "Vibe", unavailableReason: "Below percentage resolution."),
      BenchmarkQuotaChange(metricID: "api", label: "API allowance", consumedPercentagePoints: 18)
    ])
    let reason = BenchmarkCostCoverage.unavailableReason(for: run, candidate: candidate)
    XCTAssertTrue(reason?.contains("Below percentage resolution") == true)
    XCTAssertTrue(reason?.contains("API allowance") == true)
    XCTAssertNil(run.estimatedCost)
  }
}
