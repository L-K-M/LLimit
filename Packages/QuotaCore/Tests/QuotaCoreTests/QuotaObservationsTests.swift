import XCTest
@testable import QuotaCore

final class QuotaObservationsTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
  private let account = ProviderAccount(id: "claude-a", provider: .anthropic, displayName: "Personal")

  private var window: ClosedRange<Date> { t0...t0.addingTimeInterval(3_600) }

  private func usage(_ id: String = "claude-a", at date: Date, remaining: Int = 60) -> ProviderUsage {
    ProviderUsage(
      accountID: id, provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining)], fetchedAt: date
    )
  }

  private func failure(_ id: String = "claude-a", provider: QuotaProvider = .anthropic) -> ProviderFailure {
    ProviderFailure(accountID: id, provider: provider, kind: .network, message: "Unavailable")
  }

  private func snapshot(_ usages: [ProviderUsage], at date: Date, failures: [ProviderFailure] = []) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, providers: usages, failures: failures)
  }

  func testSuccessFollowedByFailedCarriesKeepsOnlyOriginalObservation() {
    let success = snapshot([usage(at: t0)], at: t0.addingTimeInterval(5))
    let failed = snapshot([], at: t0.addingTimeInterval(900), failures: [failure()])
      .mergingStaleUsage(from: success)
    let failedAgain = snapshot([], at: t0.addingTimeInterval(1_800), failures: [failure()])
      .mergingStaleUsage(from: failed)

    let observations = QuotaObservations.extract(
      from: [success, failed, failedAgain], accounts: [account], window: window
    )

    XCTAssertEqual(observations.count, 1)
    XCTAssertEqual(observations.first?.fetchedAt, t0)
    XCTAssertEqual(observations.first?.metrics.first?.remainingPercent, 60)
    XCTAssertEqual(failedAgain.providers, success.providers)
    XCTAssertEqual(failedAgain.failures, [failure()])
  }

  func testFailureOnlyArchiveCannotInventSuccessfulObservation() {
    let carried = snapshot([usage(at: t0)], at: t0.addingTimeInterval(900), failures: [failure()])
    XCTAssertTrue(QuotaObservations.extract(from: [carried], accounts: [account], window: window).isEmpty)
  }

  func testTargetedRefreshKeepsOneSiblingAndUsesFetchTimesDespiteSameGeneratedAt() {
    let sibling = ProviderAccount(id: "claude-b", provider: .anthropic)
    let base = snapshot([usage(at: t0), usage(sibling.id, at: t0)], at: t0)
    let retry = snapshot([usage(at: t0.addingTimeInterval(900), remaining: 50)], at: t0.addingTimeInterval(900))
    let targeted = base.replacingResults(forAccountIDs: [account.id], from: retry)

    let observations = QuotaObservations.extract(
      from: [base, targeted], accounts: [account, sibling], window: window
    )

    XCTAssertEqual(observations.filter { $0.accountID == sibling.id }.map(\.fetchedAt), [t0])
    XCTAssertEqual(observations.filter { $0.accountID == account.id }.map(\.fetchedAt), [t0, t0.addingTimeInterval(900)])
    XCTAssertEqual(targeted.providers.count, 2)
  }

  func testEqualValuesAtDistinctFetchSecondsRemainDistinctIncludingAdjacentSeconds() {
    let dates = [t0.addingTimeInterval(0.9), t0.addingTimeInterval(1.1), t0.addingTimeInterval(900)]
    let history = dates.reversed().map { snapshot([usage(at: $0)], at: t0.addingTimeInterval(1_000)) }
    let observations = QuotaObservations.extract(from: history, accounts: [account], window: window)

    XCTAssertEqual(observations.map(\.fetchedAt), dates)
    XCTAssertEqual(observations.compactMap { $0.metrics.first?.remainingPercent }, [60, 60, 60])
  }

  func testWindowBoundsUseSourceFetchTimeAndIncludeBothEndpoints() {
    let dates = [t0.addingTimeInterval(-1), t0, window.upperBound, window.upperBound.addingTimeInterval(1)]
    let history = dates.enumerated().map { index, date in
      snapshot([usage(at: date)], at: index == 1 ? t0.addingTimeInterval(-900) : t0.addingTimeInterval(60))
    }
    let observations = QuotaObservations.extract(from: history, accounts: [account], window: window)

    XCTAssertEqual(observations.map(\.fetchedAt), [window.lowerBound, window.upperBound])
  }

  func testOldCurrentDataDoesNotBecomeAnObservedNowEndpoint() {
    let oldCurrent = snapshot([usage(at: t0.addingTimeInterval(-86_400))], at: window.upperBound)
    let observations = QuotaObservations.extract(from: [oldCurrent], accounts: [account], window: window)

    XCTAssertTrue(observations.isEmpty)
    XCTAssertEqual(oldCurrent.providers.first?.metrics.first?.remainingPercent, 60)
  }

  func testCurrentReadingEndsAtFetchTimeWithoutExtendingToNow() {
    let fetchedAt = t0.addingTimeInterval(900)
    let current = snapshot([usage(at: fetchedAt)], at: window.upperBound)
    let observations = QuotaObservations.extract(from: [current], accounts: [account], window: window)

    XCTAssertEqual(observations.map(\.fetchedAt), [fetchedAt])
    XCTAssertLessThan(observations[0].fetchedAt, window.upperBound)
  }

  func testPersistedAndInMemoryTimestampsDeduplicateWithoutLosingSourcePrecision() throws {
    let fetchedAt = t0.addingTimeInterval(0.75)
    let current = snapshot([usage(at: fetchedAt)], at: fetchedAt)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let persisted = try decoder.decode(QuotaSnapshot.self, from: encoder.encode(current))
    XCTAssertEqual(persisted.providers.first?.fetchedAt, t0)

    for sources in [[persisted, current], [current, persisted]] {
      let observations = QuotaObservations.extract(from: sources, accounts: [account], window: window)
      XCTAssertEqual(observations.map(\.fetchedAt), [fetchedAt])
    }
  }

  func testSameFetchSecondIsConservativelyOneObservation() {
    let sources = [0.2, 0.8].map { offset in snapshot([usage(at: t0.addingTimeInterval(offset))], at: t0) }
    let observations = QuotaObservations.extract(from: sources, accounts: [account], window: window)

    XCTAssertEqual(observations.count, 1)
    XCTAssertEqual(observations.first?.fetchedAt, t0.addingTimeInterval(0.8))
  }

  func testDedupeBeforeWindowFilterDoesNotTurnRoundedFutureCopyIntoObservation() {
    let persisted = snapshot([usage(at: window.upperBound)], at: window.upperBound)
    let current = snapshot([usage(at: window.upperBound.addingTimeInterval(0.75))], at: window.upperBound)

    XCTAssertTrue(QuotaObservations.extract(
      from: [persisted, current], accounts: [account], window: window
    ).isEmpty)
  }

  func testLegacyAndUUIDReadingsJoinSoleConfiguredOwnerBeforeDedupe() {
    let legacy = snapshot([usage(QuotaProvider.anthropic.rawValue, at: t0)], at: t0)
    let current = snapshot([usage(at: t0), usage(at: t0.addingTimeInterval(900))], at: t0.addingTimeInterval(900))
    let sources = [legacy, current]
    let observations = QuotaObservations.extract(from: sources, accounts: [account], window: window)

    XCTAssertEqual(observations.map(\.accountID), [account.id, account.id])
    XCTAssertEqual(observations.map(\.title), [account.resolvedDisplayName, account.resolvedDisplayName])
    XCTAssertEqual(observations.map(\.fetchedAt), [t0, t0.addingTimeInterval(900)])
    XCTAssertEqual(sources[0].providers.first?.accountID, QuotaProvider.anthropic.rawValue)
  }

  func testDisabledSiblingMakesLegacyOwnerAmbiguousButKeepsExactUUID() {
    let disabledSibling = ProviderAccount(id: "claude-b", provider: .anthropic, isEnabled: false)
    let sources = [snapshot([usage(QuotaProvider.anthropic.rawValue, at: t0), usage(at: t0.addingTimeInterval(900))], at: t0)]
    let accounts = [account, disabledSibling]
    let observations = QuotaObservations.extract(from: sources, accounts: accounts, window: window)

    XCTAssertEqual(observations.map(\.accountID), [account.id])
    XCTAssertEqual(observations.map(\.fetchedAt), [t0.addingTimeInterval(900)])
    XCTAssertEqual(observations, sources[0].reconciled(with: accounts).providers)
  }

  func testLegacyFailureExcludesCanonicalUsageInSameSnapshot() {
    let failed = snapshot([usage(at: t0)], at: t0, failures: [failure(QuotaProvider.anthropic.rawValue)])
    let observations = QuotaObservations.extract(from: [failed], accounts: [account], window: window)

    XCTAssertTrue(observations.isEmpty)
  }

  func testFailureMatchesProviderAndAccountWithoutDiscardingSiblingSuccess() {
    let sibling = ProviderAccount(id: "claude-b", provider: .anthropic)
    let sources = [snapshot(
      [usage(at: t0), usage(sibling.id, at: t0)], at: t0,
      failures: [failure(provider: .openAI), failure(sibling.id)]
    )]
    let observations = QuotaObservations.extract(from: sources, accounts: [account, sibling], window: window)

    XCTAssertEqual(observations.map(\.accountID), [account.id])
  }

  func testExactAccountIDWithWrongProviderIsNotAnObservation() {
    var wrongProvider = usage(at: t0)
    wrongProvider.provider = .openAI
    XCTAssertTrue(QuotaObservations.extract(
      from: [snapshot([wrongProvider], at: t0)], accounts: [account], window: window
    ).isEmpty)
  }

  func testExtractionPreservesUnlimitedAndAmountOnlyMetrics() {
    var original = usage(at: t0)
    original.metrics = [
      UsageMetric(id: "unlimited", label: "Unlimited", isUnlimited: true),
      UsageMetric(id: "balance", label: "Credits", remainingAmount: 4.25)
    ]
    let observations = QuotaObservations.extract(
      from: [snapshot([original], at: t0)], accounts: [account], window: window
    )

    XCTAssertEqual(observations.first?.metrics, original.metrics)
    XCTAssertTrue(observations[0].metrics[0].isUnlimited)
    XCTAssertNil(observations[0].metrics[1].remainingPercent)
  }
}
