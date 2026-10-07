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

  func testClaudeExtraUsageAmountReachesLinuxWithoutBecomingTheHeadline() throws {
    let usage = ProviderUsage(
      accountID: "claude-account", provider: .anthropic, title: "Claude",
      metrics: [
        UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 60),
        UsageMetric(id: "seven_day", label: "Weekly limit", remainingPercent: 25),
        UsageMetric(id: "extra_usage", label: "Extra usage", usedDisplay: "$50.00", totalDisplay: "$50.00",
                    detail: "Monthly spending cap reached.")
      ],
      maxUsagePercent: 75, fetchedAt: now
    )
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["text"] as? String, "Claude 25%")
    XCTAssertEqual(object["percentage"] as? Int, 25)
    let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
    let extra = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.last)
    XCTAssertNil(extra["remainingPercent"])
    XCTAssertEqual(extra["usageLine"] as? String, "$50.00 / $50.00")
    XCTAssertEqual(extra["detail"] as? String, "Monthly spending cap reached.")
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("Weekly limit 25% left · Extra usage $50.00 / $50.00"))
  }

  func testHumanReadableWithoutSnapshotExplainsNextStep() {
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: nil, now: now).contains("llimit refresh"))
  }

  // MARK: - Failing and stale accounts

  private func accounts(_ object: [String: Any]) throws -> [[String: Any]] {
    try XCTUnwrap(object["accounts"] as? [[String: Any]])
  }

  func testFailedAccountWithCarriedDataIsFlaggedAndRaisesClass() throws {
    let snapshot = snapshot(
      remaining: [80, 90],
      failures: [ProviderFailure(accountID: "account-1", provider: .anthropic, kind: .auth, message: "token expired")]
    )
    let object = try decodedWaybar(snapshot)
    let rows = try accounts(object)

    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertEqual(object["text"] as? String, "Claude 1 80% · Claude 2 90%!")
    XCTAssertEqual(rows[0]["failed"] as? Bool, false)
    XCTAssertEqual(rows[0]["lastKnown"] as? Bool, false)
    XCTAssertNil(rows[0]["error"])
    XCTAssertEqual(rows[1]["failed"] as? Bool, true)
    XCTAssertEqual(rows[1]["lastKnown"] as? Bool, true)
    XCTAssertEqual(rows[1]["errorKind"] as? String, "auth")
    XCTAssertEqual(rows[1]["error"] as? String, "token expired")
    XCTAssertEqual(rows[1]["remainingPercent"] as? Int, 90)
    XCTAssertEqual(rows[1]["fetchedAt"] as? String, "2023-11-14T22:08:20Z")

    let failures = try XCTUnwrap(object["failures"] as? [[String: Any]])
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(failures[0]["id"] as? String, "account-1")
    XCTAssertEqual(failures[0]["provider"] as? String, "anthropic")
    XCTAssertEqual(failures[0]["name"] as? String, "Claude 2")
    XCTAssertEqual(failures[0]["errorKind"] as? String, "auth")
    // The summary names and classifies; the message stays on the account.
    XCTAssertNil(failures[0]["error"])
  }

  func testHealthySnapshotHasAnEmptyFailureSummary() throws {
    let object = try decodedWaybar(snapshot(remaining: [80]))
    XCTAssertEqual((object["failures"] as? [Any])?.count, 0)
    XCTAssertEqual(try accounts(object)[0]["failed"] as? Bool, false)
  }

  func testEveryAccountFailedWithCarriedDataIsError() throws {
    let snapshot = snapshot(
      remaining: [80, 90],
      failures: [
        ProviderFailure(accountID: "account-0", provider: .anthropic, kind: .network, message: "offline"),
        ProviderFailure(accountID: "account-1", provider: .anthropic, kind: .network, message: "offline")
      ]
    )
    XCTAssertEqual(try decodedWaybar(snapshot)["class"] as? String, "error")
  }

  func testFailingAccountsCarriedValueNeverRaisesClassAboveWarning() throws {
    let snapshot = snapshot(
      remaining: [80, 5],
      failures: [ProviderFailure(accountID: "account-1", provider: .anthropic, kind: .auth, message: "expired")]
    )
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["class"] as? String, "warning")
    // The headline number still shows the last-known value, flagged by the class and `failed`.
    XCTAssertEqual(object["percentage"] as? Int, 5)
  }

  func testStaleAccountsLastKnownValueNeverRaisesClassAboveWarning() throws {
    var snapshot = snapshot(remaining: [80, 5])
    snapshot.providers[1].fetchedAt = now.addingTimeInterval(-7 * 3_600)
    var object = try decodedWaybar(snapshot)

    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertEqual(object["percentage"] as? Int, 5)

    snapshot.providers.removeFirst()
    object = try decodedWaybar(snapshot)
    XCTAssertEqual(object["class"] as? String, "warning")
  }

  func testCarriedReadingTakenAfterItsResetIsKeptAtRenderTime() throws {
    var snapshot = snapshot(
      remaining: [80, 30],
      failures: [ProviderFailure(accountID: "account-1", provider: .anthropic, kind: .auth, message: "expired")]
    )
    // Fetched 5 min ago, after the provider's reported reset 10 min ago.
    snapshot.providers[1].metrics[0].resetAt = now.addingTimeInterval(-600)
    let rows = try accounts(decodedWaybar(snapshot))

    XCTAssertEqual(rows[1]["remainingPercent"] as? Int, 30)
  }

  func testCarriedValuePastItsResetIsNotPresentedAsCurrent() throws {
    var snapshot = snapshot(
      remaining: [80, 8],
      failures: [ProviderFailure(accountID: "account-1", provider: .anthropic, kind: .auth, message: "expired")]
    )
    // Reset passed after the daemon's last merge but before this render.
    snapshot.providers[1].metrics[0].resetAt = now.addingTimeInterval(-60)
    snapshot.providers[1].metrics[0].resetIn = "4m"
    let object = try decodedWaybar(snapshot)
    let rows = try accounts(object)

    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertEqual(object["percentage"] as? Int, 80)
    XCTAssertTrue(rows[1]["remainingPercent"] is NSNull)
    let metric = try XCTUnwrap((rows[1]["metrics"] as? [[String: Any]])?.first)
    XCTAssertNil(metric["remainingPercent"])
    XCTAssertNil(metric["resetIn"])
    XCTAssertEqual(object["text"] as? String, "Claude 1 80% · Claude 2!")
    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: now)
    XCTAssertFalse(human.contains("8% left"))
    XCTAssertTrue(human.contains("5-hour limit reset since the last successful refresh"))
  }

  func testFailureOnlyAccountIsListedWithoutData() throws {
    let snapshot = snapshot(
      remaining: [80],
      failures: [ProviderFailure(accountID: "5F2C9A71-0000", provider: .kimi, kind: .auth, message: "bad key")]
    )
    let object = try decodedWaybar(snapshot)
    let rows = try accounts(object)

    XCTAssertEqual(rows.count, 2)
    let kimi = try XCTUnwrap(rows.first { $0["provider"] as? String == "kimi" })
    XCTAssertEqual(kimi["name"] as? String, "Kimi (5F2C9A71)")
    XCTAssertTrue(kimi["remainingPercent"] is NSNull)
    XCTAssertEqual((kimi["metrics"] as? [Any])?.count, 0)
    XCTAssertEqual(kimi["failed"] as? Bool, true)
    XCTAssertEqual(kimi["lastKnown"] as? Bool, false)
    XCTAssertNil(kimi["fetchedAt"])
    XCTAssertEqual(object["text"] as? String, "Claude 1 80% · Kimi (5F2C9A71)!")
    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("Kimi (5F2C9A71): ERROR bad key"))
  }

  func testSameProviderFailuresAreNamedByAccount() throws {
    var snapshot = snapshot(
      remaining: [80, 90],
      failures: [
        ProviderFailure(accountID: "account-0", provider: .anthropic, kind: .auth, message: "expired"),
        ProviderFailure(accountID: "account-1", provider: .anthropic, kind: .network, message: "offline")
      ]
    )
    snapshot.providers[0].title = "Claude Work"
    snapshot.providers[1].title = "Claude Personal"
    let text = StatusRenderer.humanReadable(snapshot: snapshot, now: now)

    XCTAssertTrue(text.contains("Claude Work: ERROR expired"))
    XCTAssertTrue(text.contains("Claude Personal: ERROR offline"))
    XCTAssertFalse(text.contains("Claude: ERROR"))
    // Accounts (and their ERROR lines) are listed by name.
    let personal = try XCTUnwrap(text.range(of: "Claude Personal: ERROR"))
    let work = try XCTUnwrap(text.range(of: "Claude Work: ERROR"))
    XCTAssertLessThan(personal.lowerBound, work.lowerBound)
    XCTAssertTrue(text.contains("Claude Work (last known, 5 min ago): 5-hour limit 80% left"))
  }

  func testStaleThresholdDoesNotFlagHealthyAccountsBetweenSlowCycles() throws {
    // At the longest (180-minute) interval a healthy account is up to 3 h old.
    var snapshot = snapshot(remaining: [80])
    snapshot.providers[0].fetchedAt = now.addingTimeInterval(-3 * 3_600)
    var object = try decodedWaybar(snapshot)
    XCTAssertEqual(try accounts(object)[0]["stale"] as? Bool, false)
    XCTAssertEqual(object["class"] as? String, "ok")

    snapshot.providers[0].fetchedAt = now.addingTimeInterval(-7 * 3_600)
    object = try decodedWaybar(snapshot)
    XCTAssertEqual(try accounts(object)[0]["stale"] as? Bool, true)
    XCTAssertEqual(object["class"] as? String, "warning")
    XCTAssertEqual(object["text"] as? String, "Claude 1 80%!")
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("Claude 1 (stale, 7 h ago): 5-hour limit 80% left"))
  }

  func testResetCountdownIsComputedAtRenderTime() throws {
    let fetchedAt = now.addingTimeInterval(-1_800)
    let usage = ProviderUsage(
      accountID: "acct", provider: .anthropic, title: "Claude",
      metrics: [UsageMetric(id: "five-hour", label: "5-hour limit", remainingPercent: 40,
                            resetAt: fetchedAt.addingTimeInterval(3_600), resetIn: "1h")],
      fetchedAt: fetchedAt
    )
    let snapshot = QuotaSnapshot(generatedAt: fetchedAt, providers: [usage], failures: [])

    // 30 minutes after the fetch the frozen "1h" would be wrong.
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now)
      .contains("5-hour limit 40% left (resets in 30m)"))
    var metric = try XCTUnwrap((try accounts(decodedWaybar(snapshot))[0]["metrics"] as? [[String: Any]])?.first)
    XCTAssertEqual(metric["resetIn"] as? String, "30m")
    XCTAssertEqual(metric["resetAt"] as? String, "2023-11-14T22:43:20Z")

    // Past the reset: no countdown, and the human line says the reset is due.
    let later = now.addingTimeInterval(7_200)
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: later)
      .contains("5-hour limit 40% left (reset due)"))
    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: later)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    metric = try XCTUnwrap((try accounts(object)[0]["metrics"] as? [[String: Any]])?.first)
    XCTAssertNil(metric["resetIn"])
    XCTAssertEqual(metric["resetAt"] as? String, "2023-11-14T22:43:20Z")
  }

  func testResetAtIsAbsentWithoutAResetTime() throws {
    let metric = try XCTUnwrap((try accounts(decodedWaybar(snapshot(remaining: [50])))[0]["metrics"]
      as? [[String: Any]])?.first)
    XCTAssertNil(metric["resetAt"])
    XCTAssertNil(metric["resetIn"])
  }

  func testErrorTextIsOneBoundedLineWithoutMarkupOrControls() throws {
    let body = "HTTP 502: <!DOCTYPE html>\n<html><head><style>body { color: red }</style>"
      + "<title>502 Bad Gateway</title></head>\r\n<body>\u{1B}[31mnginx\u{7}%{A1:rm -rf ~:}"
      + String(repeating: " filler", count: 60) + "</body></html>"
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(accountID: "openai", provider: .openAI, kind: .api, message: body)]
    )
    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: now)
    let errorLine = try XCTUnwrap(human.split(separator: "\n").first { $0.contains("ERROR") })
    let object = try decodedWaybar(snapshot)
    let error = try XCTUnwrap(try accounts(object)[0]["error"] as? String)

    XCTAssertEqual(error, String(errorLine.dropFirst("OpenAI: ERROR ".count)))
    // Polybar would parse "%{A1:…:}" as a click-to-run region.
    XCTAssertTrue(error.hasPrefix("HTTP 502: 502 Bad Gateway nginx % {A1:rm -rf ~:} filler"))
    XCTAssertTrue(error.hasSuffix("…"))
    XCTAssertLessThanOrEqual(error.count, 160)
    for forbidden in ["<", ">", "color", "\u{1B}", "\u{7}", "\r", "\n", "  ", "%{"] {
      XCTAssertFalse(error.contains(forbidden), "error text contains \(forbidden.debugDescription)")
    }
    XCTAssertTrue((object["tooltip"] as? String)?.contains("OpenAI: ERROR \(error)") == true)
  }

  func testErrorTextScanIsBounded() {
    // Text past the scan limit is never read, so a huge unterminated page stays cheap.
    let padding = String(repeating: " ", count: StatusRenderer.maximumScannedErrorLength)
    XCTAssertEqual(StatusRenderer.sanitizedErrorText(padding + "late detail"), "")

    let unterminated = String(repeating: "<style>", count: 20_000)
    XCTAssertEqual(StatusRenderer.sanitizedErrorText("HTTP 503 " + unterminated), "HTTP 503")
    XCTAssertEqual(StatusRenderer.sanitizedErrorText("Blocked <script>var a = 1;\nvar b = 2;"), "Blocked")
  }

  func testScanCutInsideATagLeavesNoFragment() {
    let head = "HTTP 502 "
    let filler = String(repeating: "<br>", count: 1_000)
    // Pad so the scan cut lands eight characters into the div tag: "<div cla".
    let padding = String(repeating: " ", count: StatusRenderer.maximumScannedErrorLength - 8 - head.count - filler.count)
    let message = head + filler + padding + #"<div class="wrapper">Body</div>"#

    XCTAssertEqual(StatusRenderer.sanitizedErrorText(message), "HTTP 502")
  }

  func testLengthCutInsideATagLeavesNoFragment() {
    // "<bold < 5" is not a complete tag, so it survives until the length cut splits it.
    let words = String(repeating: "x", count: 155)
    XCTAssertEqual(StatusRenderer.sanitizedErrorText(words + " <bold < 5 ok"), words + "…")
  }

  func testErrorTextKeepsComparisonsThatAreNotMarkup() {
    XCTAssertEqual(StatusRenderer.sanitizedErrorText("limit < 5 and > 2"), "limit < 5 and > 2")
  }

  func testMarkupOnlyErrorFallsBackToItsKind() throws {
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(accountID: "kimi", provider: .kimi, kind: .api, message: "<html>\n</html>")]
    )
    XCTAssertEqual(try accounts(decodedWaybar(snapshot))[0]["error"] as? String, "Refresh failed (api)")
  }

  func testFailureOnlyAccountIsNamedByItsRecordedTitle() throws {
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [],
      failures: [ProviderFailure(accountID: "5F2C9A71-0000", provider: .anthropic, kind: .auth,
                                 message: "expired", title: "Claude Work")]
    )
    let object = try decodedWaybar(snapshot)

    XCTAssertEqual(try accounts(object)[0]["name"] as? String, "Claude Work")
    XCTAssertEqual(object["text"] as? String, "Claude Work!")
    XCTAssertEqual(object["class"] as? String, "error")
    XCTAssertNil(object["percentage"])
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("Claude Work: ERROR expired"))
  }
}
