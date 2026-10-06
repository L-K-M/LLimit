import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class StatusRendererTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func snapshot(remaining: [Int], failures: [ProviderFailure] = []) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now.addingTimeInterval(-300),
      providers: remaining.enumerated().map { index, percent in
        ProviderUsage(
          accountID: "account-\(index)",
          provider: .anthropic,
          title: "Claude \(index + 1)",
          metrics: [UsageMetric(id: "five-hour", label: "5-hour limit", remainingPercent: percent)],
          fetchedAt: now.addingTimeInterval(-300)
        )
      },
      failures: failures
    )
  }

  private func decodedWaybar(_ snapshot: QuotaSnapshot?) throws -> [String: Any] {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testWaybarJSONHasWaybarContractKeys() throws {
    let object = try decodedWaybar(snapshot(remaining: [73, 41]))

    XCTAssertEqual(object["text"] as? String, "Claude 1 73% · Claude 2 41%")
    XCTAssertEqual(object["class"] as? String, "ok")
    XCTAssertEqual(object["percentage"] as? Int, 41)
    XCTAssertNotNil(object["tooltip"])
    XCTAssertEqual((object["accounts"] as? [[String: Any]])?.count, 2)
  }

  // MARK: - Per-metric rows (consumed by the tray popup)

  func testAccountsCarryEveryMetricAsItsOwnRow() throws {
    let usage = ProviderUsage(
      accountID: "acct",
      provider: .anthropic,
      title: "Claude",
      metrics: [
        UsageMetric(id: "session", label: "Session", remainingPercent: 62, resetIn: "3h 12m"),
        UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 8, resetIn: "4d 2h")
      ],
      fetchedAt: now
    )
    let object = try decodedWaybar(
      QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    )

    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 2)
    XCTAssertEqual(metrics[0]["label"] as? String, "Session")
    XCTAssertEqual(metrics[0]["remainingPercent"] as? Int, 62)
    XCTAssertEqual(metrics[0]["resetIn"] as? String, "3h 12m")
    XCTAssertEqual(metrics[1]["label"] as? String, "Weekly")
    XCTAssertEqual(metrics[1]["remainingPercent"] as? Int, 8)
    // The headline stays the worst metric, so existing bars are unchanged.
    XCTAssertEqual(account["remainingPercent"] as? Int, 8)
  }

  func testUnlimitedMetricIsFlaggedAndOmitsRemainingPercent() throws {
    let usage = ProviderUsage(
      accountID: "acct",
      provider: .zhipu,
      title: "Zhipu AI",
      metrics: [UsageMetric(id: "plan", label: "Plan", isUnlimited: true)],
      fetchedAt: now
    )
    let object = try decodedWaybar(
      QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    )

    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(metric["unlimited"] as? Bool, true)
    // Absent, not null: the tray uses plain key lookup.
    XCTAssertNil(metric["remainingPercent"])
    XCTAssertNil(metric["resetIn"])
    XCTAssertEqual(metric["usageLine"] as? String, "Unlimited")
  }

  func testMetricsAreEmittedForEveryAccount() throws {
    let object = try decodedWaybar(snapshot(remaining: [73, 41]))
    let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
    for account in accounts {
      XCTAssertEqual((account["metrics"] as? [[String: Any]])?.count, 1)
    }
  }

  func testWaybarClassFollowsLowestRemainingPercent() throws {
    XCTAssertEqual(try decodedWaybar(snapshot(remaining: [80]))["class"] as? String, "ok")
    XCTAssertEqual(try decodedWaybar(snapshot(remaining: [25]))["class"] as? String, "warning")
    XCTAssertEqual(try decodedWaybar(snapshot(remaining: [5]))["class"] as? String, "critical")
  }

  func testWaybarWithoutSnapshotIsEmpty() throws {
    let object = try decodedWaybar(nil)
    XCTAssertEqual(object["class"] as? String, "empty")
  }

  func testBalanceOnlyAccountShowsAmountsWithoutInventingPercentage() throws {
    let usage = ProviderUsage(
      accountID: "balance-account",
      provider: .venice,
      title: "Balance account",
      metrics: [
        UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", usedDisplay: "12.50 DIEM"),
        UsageMetric(id: "usd-balance", label: "USD balance", usedDisplay: "$3.25")
      ],
      fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["text"] as? String,
                   "Balance account Daily DIEM remaining 12.50 DIEM / USD balance $3.25")
    XCTAssertNil(object["percentage"])
    XCTAssertEqual(object["class"] as? String, "ok")
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    XCTAssertTrue(account["remainingPercent"] is NSNull)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertTrue(metrics.allSatisfy { $0["remainingPercent"] == nil })
    XCTAssertEqual(metrics[1]["usageLine"] as? String, "$3.25")
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("Daily DIEM remaining 12.50 DIEM · USD balance $3.25"))
  }

  func testEstimatedDailyBalanceIsMarkedInTextAndJSON() throws {
    let usage = ProviderUsage(
      accountID: "estimated-account", provider: .venice, title: "Venice",
      metrics: [UsageMetric(
        id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: 50,
        remainingAmount: 20, estimatedTotal: 40, usedDisplay: "20.00 DIEM", resetIn: "3h"
      )],
      fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["text"] as? String, "Venice ≈50%")
    XCTAssertEqual(object["percentage"] as? Int, 50)
    XCTAssertEqual(object["estimated"] as? Bool, true)
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["estimated"] as? Bool, true)
    XCTAssertEqual(metric["estimated"] as? Bool, true)
    let expected = "Daily DIEM remaining ≈50% left (estimated) (resets in 3h)"
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains(expected))
    XCTAssertTrue((object["tooltip"] as? String)?.contains(expected) == true)
  }

  func testOfficialPercentageHasNoEstimatedFlag() throws {
    let object = try decodedWaybar(snapshot(remaining: [73]))
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)

    XCTAssertNil(object["estimated"])
    XCTAssertNil(account["estimated"])
    XCTAssertNil(metric["estimated"])
    XCTAssertFalse((object["text"] as? String)?.contains("≈") == true)
    XCTAssertFalse((object["tooltip"] as? String)?.contains("estimated") == true)
  }

  func testNonHeadlineEstimateDoesNotMarkOfficialHeadline() throws {
    let usage = ProviderUsage(
      accountID: "mixed-account", provider: .venice, title: "Venice",
      metrics: [
        UsageMetric(id: "official", label: "Official", remainingPercent: 25),
        UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: 75,
                    estimatedTotal: 40)
      ],
      fetchedAt: now
    )
    let object = try decodedWaybar(QuotaSnapshot(generatedAt: now, providers: [usage], failures: []))
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])

    XCTAssertEqual(object["text"] as? String, "Venice 25%")
    XCTAssertNil(object["estimated"])
    XCTAssertNil(account["estimated"])
    XCTAssertNil(metrics[0]["estimated"])
    XCTAssertEqual(metrics[1]["estimated"] as? Bool, true)
  }

  func testTopLevelEstimatedFlagFollowsLowestAccount() throws {
    var snapshot = snapshot(remaining: [25, 75])
    snapshot.providers[1].metrics[0].estimatedTotal = 100
    let object = try decodedWaybar(snapshot)
    let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])

    XCTAssertEqual(object["text"] as? String, "Claude 1 25% · Claude 2 ≈75%")
    XCTAssertNil(object["estimated"])
    XCTAssertNil(accounts[0]["estimated"])
    XCTAssertEqual(accounts[1]["estimated"] as? Bool, true)
  }

  func testEstimatedFlagSurvivesEqualOfficialMinimum() throws {
    var snapshot = snapshot(remaining: [25, 25])
    snapshot.providers[1].metrics[0].estimatedTotal = 100
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["estimated"] as? Bool, true)
    XCTAssertEqual(object["percentage"] as? Int, 25)
  }

  func testEstimateWithoutPercentageDoesNotClaimEstimatedPercentage() {
    let metric = UsageMetric(id: "daily-diem", label: "Daily DIEM remaining",
                             estimatedTotal: 40, usedDisplay: "0.00 DIEM")
    let object = StatusRenderer.metricObject(metric, now: now)

    XCTAssertNil(object["remainingPercent"])
    XCTAssertNil(object["estimated"])
  }

  // MARK: - Live reset countdowns

  func testMetricObjectCarriesAbsoluteResetAndLiveSeconds() throws {
    let resetAt = now.addingTimeInterval(3 * 3600 + 12 * 60)
    let metric = UsageMetric(id: "weekly", label: "Weekly limit",
                             remainingPercent: 40, resetAt: resetAt, resetIn: "3h 12m")

    let object = StatusRenderer.metricObject(metric, now: now)

    XCTAssertEqual(object["resetSeconds"] as? Int, 3 * 3600 + 12 * 60)
    // The frozen fetch-time string is still present for older consumers.
    XCTAssertEqual(object["resetIn"] as? String, "3h 12m")
    let iso = try XCTUnwrap(object["resetAt"] as? String)
    XCTAssertTrue(iso.hasSuffix("Z"))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let reparsed = try XCTUnwrap(formatter.date(from: iso))
    XCTAssertEqual(reparsed.timeIntervalSince1970, resetAt.timeIntervalSince1970, accuracy: 1)
  }

  func testMetricObjectOmitsResetFieldsWithoutResetAt() {
    let metric = UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 40, resetIn: "3h 12m")
    let object = StatusRenderer.metricObject(metric, now: now)

    XCTAssertNil(object["resetAt"])
    XCTAssertNil(object["resetSeconds"])
    XCTAssertEqual(object["resetIn"] as? String, "3h 12m")
  }

  func testMetricObjectOmitsABlankResetString() {
    // Whitespace is not a countdown; a consumer's fallback must not be able to
    // render "resets in ".
    let metric = UsageMetric(id: "weekly", label: "Weekly limit",
                             remainingPercent: 40, resetIn: "   ")
    let object = StatusRenderer.metricObject(metric, now: now)

    XCTAssertNil(object["resetIn"])
    XCTAssertNil(object["resetAt"])
  }

  func testHumanReadableTicksTheResetCountdownAgainstNow() {
    let resetAt = now.addingTimeInterval(3 * 3600 + 12 * 60)
    let usage = ProviderUsage(
      accountID: "acct", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit",
                            remainingPercent: 40, resetAt: resetAt, resetIn: "3h 12m")],
      fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])

    // Read an hour later, the countdown has moved on rather than repeating the
    // fetch-time string.
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("Weekly limit 40% left (resets in 3h 12m)"))
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now.addingTimeInterval(3600))
      .contains("Weekly limit 40% left (resets in 2h 12m)"))
  }

  func testHumanReadableFallsBackToTheFrozenResetString() {
    // `resetIn` without `resetAt`: resetCountdown(at:) returns the frozen string,
    // so the clause must still appear rather than vanish.
    let usage = ProviderUsage(
      accountID: "acct", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit",
                            remainingPercent: 40, resetIn: "3h 12m")],
      fetchedAt: now
    )
    let text = StatusRenderer.humanReadable(
      snapshot: QuotaSnapshot(generatedAt: now, providers: [usage], failures: []), now: now)

    XCTAssertTrue(text.contains("Weekly limit 40% left (resets in 3h 12m)"))
  }

  func testHumanReadableOmitsABlankResetString() {
    // A blank `resetIn` yields no countdown, so the clause is dropped instead of
    // rendering a malformed "(resets in )".
    let usage = ProviderUsage(
      accountID: "acct", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit",
                            remainingPercent: 40, resetIn: "   ")],
      fetchedAt: now
    )
    let text = StatusRenderer.humanReadable(
      snapshot: QuotaSnapshot(generatedAt: now, providers: [usage], failures: []), now: now)

    XCTAssertTrue(text.contains("Weekly limit 40% left"))
    XCTAssertFalse(text.contains("(resets in"))
  }

  func testHumanReadableMarksADueReset() {
    let usage = ProviderUsage(
      accountID: "acct", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit",
                            remainingPercent: 40, resetAt: now.addingTimeInterval(-60))],
      fetchedAt: now
    )
    let text = StatusRenderer.humanReadable(
      snapshot: QuotaSnapshot(generatedAt: now, providers: [usage], failures: []), now: now)

    XCTAssertTrue(text.contains("(reset due)"))
  }

  // MARK: - Interval-aware staleness

  func testStaleThresholdFollowsTheRefreshInterval() {
    XCTAssertEqual(StatusRenderer.staleThreshold(refreshIntervalMinutes: 15), 45 * 60)
    XCTAssertEqual(StatusRenderer.staleThreshold(refreshIntervalMinutes: 30), 45 * 60)
    XCTAssertEqual(StatusRenderer.staleThreshold(refreshIntervalMinutes: 60), 90 * 60)
    XCTAssertEqual(StatusRenderer.staleThreshold(refreshIntervalMinutes: 180), 270 * 60)
    // Out-of-range values clamp to the supported interval.
    XCTAssertEqual(StatusRenderer.staleThreshold(refreshIntervalMinutes: 0), 45 * 60)
    XCTAssertEqual(StatusRenderer.staleThreshold(refreshIntervalMinutes: 10_000), 270 * 60)
  }

  func testStaleFlagUsesTheSuppliedThreshold() throws {
    let fetchedAt = now.addingTimeInterval(-2 * 3600)
    let usage = ProviderUsage(
      accountID: "acct", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 40)],
      fetchedAt: fetchedAt
    )
    let snapshot = QuotaSnapshot(generatedAt: fetchedAt, providers: [usage], failures: [])

    func stale(staleAfter: TimeInterval) throws -> Bool {
      let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: now, staleAfter: staleAfter)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
      return account["stale"] as? Bool ?? false
    }

    // Two hours old: stale under a fast interval, fresh under a slow one, and
    // exactly at the historical default's edge.
    XCTAssertTrue(try stale(staleAfter: StatusRenderer.staleThreshold(refreshIntervalMinutes: 15)))
    XCTAssertFalse(try stale(staleAfter: StatusRenderer.staleThreshold(refreshIntervalMinutes: 180)))
    XCTAssertFalse(try stale(staleAfter: StatusRenderer.defaultStaleAfter))
  }

  func testWaybarWithOnlyFailuresIsError() throws {
    let failed = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(provider: .kimi, kind: .auth, message: "token expired")]
    )
    let object = try decodedWaybar(failed)
    XCTAssertEqual(object["class"] as? String, "error")
  }

  func testBalanceWarningReachesHumanAndJSONStatus() throws {
    let warning = "API key spending unavailable. Check its limits in Venice."
    let usage = ProviderUsage(
      accountID: "capped-key", provider: .venice, title: "Venice",
      metrics: [UsageMetric(id: "usd-balance", label: "USD balance", usedDisplay: "$5.00")],
      warning: warning, fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertNil(object["percentage"])
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains(warning))
    XCTAssertTrue((object["tooltip"] as? String)?.contains(warning) == true)
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["warning"] as? String, warning)
  }

  func testWarningElevatesHealthyQuotaWithoutMaskingCriticalQuota() throws {
    for (remaining, expectedClass) in [(80, "warning"), (25, "warning"), (5, "critical")] {
      var snapshot = snapshot(remaining: [remaining])
      snapshot.providers[0].warning = "Account needs attention"
      let object = try decodedWaybar(snapshot)
      XCTAssertEqual(object["class"] as? String, expectedClass)
      XCTAssertEqual(object["percentage"] as? Int, remaining)
    }
  }

  func testEmptyWarningsDoNotChangeHealthyStatusOrJSONContract() throws {
    for warning in [nil, "", " \n "] as [String?] {
      var snapshot = snapshot(remaining: [80])
      snapshot.providers[0].warning = warning
      let object = try decodedWaybar(snapshot)
      XCTAssertEqual(object["class"] as? String, "ok")
      let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
      XCTAssertNil(account["warning"])
      XCTAssertFalse(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("WARNING"))
    }
  }

  func testWaybarJSONIsValidAndCredentialFree() throws {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot(remaining: [50]), now: now)
    XCTAssertFalse(json.contains("access_token"))
    XCTAssertFalse(json.contains("api_key"))
  }

  func testHumanReadableListsAccountsAndFailures() {
    let text = StatusRenderer.humanReadable(
      snapshot: snapshot(
        remaining: [73],
        failures: [ProviderFailure(provider: .kimi, kind: .rateLimit, message: "slow down")]
      ),
      now: now
    )

    XCTAssertTrue(text.contains("5 min ago"))
    XCTAssertTrue(text.contains("Claude 1: 5-hour limit 73% left"))
    XCTAssertTrue(text.contains("Kimi: ERROR slow down"))
  }

  func testClinePassHeadlineAndCreditBalanceShareOneLine() throws {
    // The headline is the constrained ClinePass window; the credit balance has
    // no percentage and must not become one.
    let usage = ProviderUsage(
      accountID: "cline-account", provider: .cline, title: "Cline",
      metrics: [
        UsageMetric(id: "five_hour", label: "5-hour remaining", remainingPercent: 75, usedDisplay: "25% used"),
        UsageMetric(id: "monthly", label: "Monthly remaining", remainingPercent: 20, usedDisplay: "80% used"),
        UsageMetric(id: "credit-balance", label: "Credit balance", usedDisplay: "$4.25")
      ],
      maxUsagePercent: 80, fetchedAt: now
    )
    let object = try decodedWaybar(QuotaSnapshot(generatedAt: now, providers: [usage], failures: []))

    XCTAssertEqual(object["text"] as? String, "Cline 20%")
    XCTAssertEqual(object["percentage"] as? Int, 20)
    XCTAssertEqual(object["class"] as? String, "warning")
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertNil(metrics[2]["remainingPercent"])
    XCTAssertEqual(metrics[2]["usageLine"] as? String, "$4.25")
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: QuotaSnapshot(generatedAt: now, providers: [usage], failures: []), now: now)
      .contains("5-hour remaining 75% left · Monthly remaining 20% left · Credit balance $4.25"))
  }

  func testClineCreditOnlyAccountRendersAmountsWithoutInventingPercentage() throws {
    let usage = ProviderUsage(
      accountID: "cline-credits-only", provider: .cline, title: "Cline",
      metrics: [UsageMetric(id: "credit-balance", label: "Credit balance", usedDisplay: "$0.00")],
      warning: "No Cline credits left", fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["text"] as? String, "Cline Credit balance $0.00")
    XCTAssertNil(object["percentage"])
    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("No Cline credits left"))
  }

  func testHumanReadableWithoutSnapshotExplainsNextStep() {
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: nil, now: now).contains("llimit refresh"))
  }
}
