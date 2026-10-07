import XCTest
@testable import QuotaCore

final class QuotaObservationsTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)
  private let account = ProviderAccount(id: "a", provider: .anthropic)

  private func snapshot(_ date: Date, id: String = "a", failed: String? = nil) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: base.addingTimeInterval(3_600), providers: [
      ProviderUsage(accountID: id, provider: .anthropic, title: id,
        metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 60)], fetchedAt: date)
    ], failures: failed.map { [ProviderFailure(accountID: $0, provider: .anthropic, kind: .network, message: "offline")] } ?? [])
  }

  private func extract(_ snapshots: [QuotaSnapshot], accounts: [ProviderAccount]? = nil) -> [ProviderUsage] {
    QuotaObservations.extract(from: snapshots, accounts: accounts ?? [account], window: base...base.addingTimeInterval(3_600))
  }

  func testFailuresAndCarriesNeverInventObservationsOrNowEndpoint() {
    let success = snapshot(base.addingTimeInterval(900))
    let failed = snapshot(base.addingTimeInterval(900), failed: "a")
    XCTAssertEqual(extract([success, failed]).map(\.fetchedAt), [base.addingTimeInterval(900)])
    XCTAssertTrue(extract([failed]).isEmpty)
    XCTAssertTrue(extract([snapshot(base.addingTimeInterval(-1))]).isEmpty)
  }

  func testDedupBeforeBoundsPreservesSourcePrecisionAndDistinctEqualFetches() {
    let persisted = snapshot(base)
    let live = snapshot(base.addingTimeInterval(0.75))
    for sources in [[persisted, live], [live, persisted]] {
      XCTAssertEqual(extract(sources).map(\.fetchedAt), [base.addingTimeInterval(0.75)])
    }
    XCTAssertEqual(extract([live, snapshot(base.addingTimeInterval(1.1))]).count, 2)
    let end = base.addingTimeInterval(3_600)
    XCTAssertTrue(extract([snapshot(end), snapshot(end.addingTimeInterval(0.75))]).isEmpty)
  }

  func testLegacyOwnershipCountsDisabledSiblingsAndResolvesFailureAliases() {
    let legacy = snapshot(base, id: QuotaProvider.anthropic.rawValue)
    XCTAssertEqual(extract([legacy, snapshot(base)]).map(\.accountID), [account.id])
    let disabled = ProviderAccount(id: "b", provider: .anthropic, isEnabled: false)
    XCTAssertTrue(extract([legacy], accounts: [account, disabled]).isEmpty)
    XCTAssertTrue(extract([snapshot(base, failed: QuotaProvider.anthropic.rawValue)]).isEmpty)
  }

  func testFailureMatchingAndExactOwnershipUseProviderAsWellAsAccount() {
    var source = snapshot(base)
    source.failures = [ProviderFailure(accountID: "a", provider: .openAI, kind: .network, message: "offline")]
    XCTAssertEqual(extract([source]).count, 1)
    source.providers[0].provider = .openAI
    XCTAssertTrue(extract([source]).isEmpty)
  }

  func testBothWindowEndpointsAndAmountUnlimitedMetricsSurvive() {
    var source = snapshot(base)
    source.providers[0].metrics = [UsageMetric(id: "usd", label: "USD", remainingAmount: 4.25),
      UsageMetric(id: "chat", label: "Chat", isUnlimited: true)]
    let result = extract([source, snapshot(base.addingTimeInterval(3_600))])
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].metrics, source.providers[0].metrics)
  }
}
