import Foundation
import XCTest
@testable import QuotaCore

final class VeniceQuotaEstimateTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func fetch(_ amount: Double, previous: QuotaSnapshot? = nil, seconds: TimeInterval = 0,
                     reset: Date? = nil, percent: Int? = nil, warning: String? = nil,
                     keyHash: String? = nil,
                     accountID: String = "venice-account", provider: QuotaProvider = .venice) async -> QuotaSnapshot {
    let metric = UsageMetric(
      id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: percent, remainingAmount: amount,
      estimateKeyHash: keyHash,
      usedDisplay: "\(amount) DIEM", resetAt: reset ?? now.addingTimeInterval(3_600), detail: "API key balance.")
    let coordinator = QuotaCoordinator(clients: [EstimateClient(provider: provider, metric: metric, warning: warning)])
    return await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(accountID: accountID, provider: provider, displayName: "Venice",
                                                     isEnabled: true, credentials: [:])],
      now: now.addingTimeInterval(seconds), previousSnapshot: previous)
  }

  func testFirstBalanceAndConsumptionUseObservedUpperBound() async throws {
    let first = await fetch(40)
    XCTAssertEqual(first.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(first.providers.first?.metrics.first?.estimatedTotal, 40)
    XCTAssertEqual(first.providers.first?.maxUsagePercent, 0)
    let next = await fetch(10, previous: first, seconds: 1)
    let metric = try XCTUnwrap(next.providers.first?.metrics.first)
    XCTAssertEqual(metric.remainingPercent, 25)
    XCTAssertEqual(metric.estimatedTotal, 40)
    XCTAssertEqual(metric.remainingAmount, 10)
    XCTAssertTrue(metric.isPercentageEstimated)
    XCTAssertTrue(metric.detail?.contains("Estimated") == true)
    XCTAssertTrue(metric.detail?.contains("already be partly spent") == true)
    XCTAssertEqual(next.providers.first?.maxUsagePercent, 75)
    XCTAssertNil(next.providers.first?.metrics.last?.remainingPercent)
    XCTAssertNil(next.providers.first?.metrics.last?.estimatedTotal)
  }

  func testAnyIncreaseStartsANewObservedUpperBound() async {
    let first = await fetch(100)
    let spent = await fetch(30, previous: first, seconds: 1)
    let increased = await fetch(60, previous: spent, seconds: 2)
    XCTAssertEqual(increased.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(increased.providers.first?.metrics.first?.estimatedTotal, 60)
    let next = await fetch(30, previous: increased, seconds: 3)
    XCTAssertEqual(next.providers.first?.metrics.first?.remainingPercent, 50)
  }

  func testNewEpochStartsFreshEvenWhenFirstBalanceIsLower() async {
    let first = await fetch(100)
    let nextReset = now.addingTimeInterval(86_400 + 3_600)
    let next = await fetch(30, previous: first, seconds: 86_400, reset: nextReset)
    XCTAssertEqual(next.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(next.providers.first?.metrics.first?.estimatedTotal, 30)
    let spent = await fetch(15, previous: next, seconds: 86_401, reset: nextReset)
    XCTAssertEqual(spent.providers.first?.metrics.first?.remainingPercent, 50)
  }

  func testEstimateSurvivesSnapshotStoreReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    let fractionalReset = now.addingTimeInterval(3_600.75)
    let first = await fetch(80, reset: fractionalReset)
    let spent = await fetch(40, previous: first, seconds: 1, reset: fractionalReset)
    try store.save(spent)
    let reloaded = try XCTUnwrap(store.load())
    let next = await fetch(20, previous: reloaded, seconds: 2, reset: fractionalReset)
    XCTAssertEqual(next.providers.first?.metrics.first?.remainingPercent, 25)
    XCTAssertEqual(next.providers.first?.metrics.first?.estimatedTotal, 80)
  }

  func testServerPercentageOverridesObservedEstimate() async {
    let first = await fetch(40)
    let exact = await fetch(20, previous: first, seconds: 1, percent: 10)
    XCTAssertEqual(exact.providers.first?.metrics.first?.remainingPercent, 10)
    XCTAssertNil(exact.providers.first?.metrics.first?.estimatedTotal)
    XCTAssertFalse(exact.providers.first?.metrics.first?.isPercentageEstimated ?? true)
  }

  func testNonpositiveFirstBalanceHasNoInventedDenominator() async {
    for amount in [0.0, -2.0] {
      let first = await fetch(amount)
      XCTAssertNil(first.providers.first?.metrics.first?.remainingPercent)
      XCTAssertNil(first.providers.first?.metrics.first?.estimatedTotal)
      XCTAssertNil(first.providers.first?.maxUsagePercent)
    }
    let empty = await fetch(0)
    let refilled = await fetch(20, previous: empty, seconds: 1)
    XCTAssertEqual(refilled.providers.first?.metrics.first?.remainingPercent, 100)
  }

  func testExhaustionUsesRawBalanceAndPreservesSpendingWarnings() async {
    let first = await fetch(100)
    for amount in [0.0, -2.0] {
      let exhausted = await fetch(amount, previous: first, seconds: 1)
      XCTAssertEqual(exhausted.providers.first?.metrics.first?.remainingPercent, 0)
      XCTAssertEqual(exhausted.providers.first?.warning, "Daily DIEM exhausted")
    }
    let tiny = await fetch(0.4, previous: first, seconds: 1)
    XCTAssertEqual(tiny.providers.first?.metrics.first?.remainingPercent, 0)
    XCTAssertEqual(tiny.providers.first?.warning, "High estimated DIEM usage")
    let negative = await fetch(-2, previous: first, seconds: 1)
    let zero = await fetch(0, previous: negative, seconds: 2)
    XCTAssertEqual(zero.providers.first?.metrics.first?.remainingPercent, 0)
    XCTAssertEqual(zero.providers.first?.metrics.first?.estimatedTotal, 100)
    let blocked = await fetch(10, previous: first, seconds: 1, warning: "API key spending unavailable")
    XCTAssertEqual(blocked.providers.first?.warning, "API key spending unavailable")
  }

  func testExpiredEpochAndInvalidAmountsDoNotProduceEstimates() async {
    for amount in [40.0, .infinity, .nan] {
      let result = await fetch(amount, reset: now.addingTimeInterval(-1))
      XCTAssertNil(result.providers.first?.metrics.first?.remainingPercent)
      XCTAssertNil(result.providers.first?.metrics.first?.estimatedTotal)
    }
    for amount in [Double.infinity, Double.nan] {
      let result = await fetch(amount)
      XCTAssertNil(result.providers.first?.metrics.first?.remainingPercent)
      XCTAssertNil(result.providers.first?.metrics.first?.estimatedTotal)
    }
  }

  func testOlderAndDuplicateObservationsCannotReplaceEstimate() async {
    let first = await fetch(100)
    let latest = await fetch(50, previous: first, seconds: 2)
    for seconds in [0.0, 2.0] {
      let old = await fetch(80, previous: latest, seconds: seconds)
      XCTAssertEqual(old.providers.first, latest.providers.first)
    }
    let next = await fetch(25, previous: latest, seconds: 3)
    XCTAssertEqual(next.providers.first?.metrics.first?.remainingPercent, 25)
  }

  func testAccountAndProviderBoundariesDoNotShareUpperBounds() async {
    let first = await fetch(100, accountID: "first")
    let other = await fetch(20, previous: first, seconds: 1, accountID: "second")
    XCTAssertEqual(other.providers.first?.metrics.first?.estimatedTotal, 20)
    let unrelated = await fetch(40, previous: first, seconds: 1, provider: .zai)
    XCTAssertNil(unrelated.providers.first?.metrics.first?.remainingPercent)
    XCTAssertNil(unrelated.providers.first?.metrics.first?.estimatedTotal)
  }

  func testFailedFetchRetainsPreviousEstimateWithoutAdvancingIt() async throws {
    let first = await fetch(100)
    let spent = await fetch(50, previous: first, seconds: 1)
    let failed = await QuotaCoordinator(clients: [EstimateFailureClient()]).refresh(
      configurations: [ProviderRuntimeConfiguration(accountID: "venice-account", provider: .venice,
                                                     displayName: "Venice", isEnabled: true, credentials: [:])],
      now: now.addingTimeInterval(2), previousSnapshot: spent)
      .mergingStaleUsage(from: spent)
    XCTAssertEqual(failed.providers, spent.providers)
    XCTAssertEqual(failed.failures.count, 1)
    let recovered = await fetch(25, previous: failed, seconds: 3)
    XCTAssertEqual(recovered.providers.first?.metrics.first?.remainingPercent, 25)
  }

  func testReplacedKeyDoesNotInheritPreviousKeysEstimate() async {
    let first = await fetch(100, keyHash: credentialFingerprint("key-A"))
    let spent = await fetch(50, previous: first, seconds: 1, keyHash: credentialFingerprint("key-A"))
    XCTAssertEqual(spent.providers.first?.metrics.first?.remainingPercent, 50)
    // A replacement key's first reading starts a fresh observation instead of
    // measuring its balance against the old key's denominator.
    let replaced = await fetch(30, previous: spent, seconds: 2, keyHash: credentialFingerprint("key-B"))
    XCTAssertEqual(replaced.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(replaced.providers.first?.metrics.first?.estimatedTotal, 30)
    let spentNewKey = await fetch(15, previous: replaced, seconds: 3, keyHash: credentialFingerprint("key-B"))
    XCTAssertEqual(spentNewKey.providers.first?.metrics.first?.remainingPercent, 50)
  }

  func testUnstampedPriorSnapshotDoesNotCarryOntoStampedKey() async {
    // Snapshots written before the fingerprint existed have no stamp; the
    // first stamped refresh must not inherit their estimate.
    let legacy = await fetch(100)
    let stamped = await fetch(40, previous: legacy, seconds: 1, keyHash: credentialFingerprint("key-A"))
    XCTAssertEqual(stamped.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(stamped.providers.first?.metrics.first?.estimatedTotal, 40)
  }

  func testLegacyMetricsStillDecodeAndDoNotParseFormattedBalances() async throws {
    let data = Data(#"{"id":"daily-diem","label":"Daily DIEM remaining","usedDisplay":"999 DIEM","isUnlimited":false}"#.utf8)
    let legacy = try JSONDecoder().decode(UsageMetric.self, from: data)
    XCTAssertNil(legacy.remainingAmount)
    XCTAssertNil(legacy.estimatedTotal)
    let previous = QuotaSnapshot(generatedAt: now, providers: [
      ProviderUsage(accountID: "venice-account", provider: .venice, title: "Venice", metrics: [legacy], fetchedAt: now)
    ], failures: [])
    let first = await fetch(40, previous: previous, seconds: 1)
    XCTAssertEqual(first.providers.first?.metrics.first?.estimatedTotal, 40)
  }
}

private struct EstimateClient: QuotaProviderClient {
  let provider: QuotaProvider
  let metric: UsageMetric
  let warning: String?

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
                  metrics: [metric, UsageMetric(id: "usd-balance", label: "USD balance", usedDisplay: "$10.00")],
                  maxUsagePercent: metric.remainingPercent.map { 100 - $0 }, warning: warning, fetchedAt: now)
  }
}

private struct EstimateFailureClient: QuotaProviderClient {
  let provider: QuotaProvider = .venice
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw ProviderClientError(kind: .network, message: "Temporary fixture failure")
  }
}
