import XCTest
@testable import QuotaCore
@testable import LLimitdCore

// PR #105 honest rendering, #64 failure priority, #50 countdowns, #83/#88 summaries.
final class StatusContractTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func usage(_ id: String, remaining: Int = 80, age: TimeInterval = 300) -> ProviderUsage {
    ProviderUsage(accountID: id, provider: .anthropic, title: id,
                  metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining)], fetchedAt: now.addingTimeInterval(-age))
  }
  private func object(_ snapshot: QuotaSnapshot?) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(StatusRenderer.waybarJSON(snapshot: snapshot, now: now).utf8)) as? [String: Any])
  }

  func testFailedAndLastKnownContractRetainsNumbersWithoutFalseCritical() throws {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage("fresh"), usage("failed", remaining: 5)], failures: [
      ProviderFailure(accountID: "failed", provider: .anthropic, kind: .auth, message: "expired")
    ])
    let json = try object(snapshot)
    XCTAssertEqual(json["class"] as? String, "warning")
    XCTAssertEqual(json["percentage"] as? Int, 5)
    let accounts = try XCTUnwrap(json["accounts"] as? [[String: Any]])
    let failed = try XCTUnwrap(accounts.first { $0["id"] as? String == "failed" })
    XCTAssertEqual(failed["failed"] as? Bool, true)
    XCTAssertEqual(failed["lastKnown"] as? Bool, true)
    XCTAssertEqual(failed["errorKind"] as? String, "auth")
    XCTAssertEqual(failed["remainingPercent"] as? Int, 5)
    XCTAssertNil(failed["failing"])
    XCTAssertEqual((json["failures"] as? [[String: Any]])?.count, 1)
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("failed (last known, 5 min ago)"))
    var allFailed = snapshot
    allFailed.failures.append(.init(accountID: "fresh", provider: .anthropic, kind: .network, message: "offline"))
    XCTAssertEqual(try object(allFailed)["class"] as? String, "error")
  }

  func testElapsedCarriedWindowClearsOnlyObsoleteReadingAtRenderTime() throws {
    var old = usage("old", remaining: 8)
    old.metrics[0].resetAt = now.addingTimeInterval(-60)
    old.metrics.append(UsageMetric(id: "session", label: "Session", remainingPercent: 60, resetAt: now.addingTimeInterval(600)))
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [old], failures: [ProviderFailure(accountID: "old", provider: .anthropic, kind: .auth, message: "expired")])
    let account = try XCTUnwrap((try object(snapshot)["accounts"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["remainingPercent"] as? Int, 60)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertNil(metrics[0]["remainingPercent"])
    XCTAssertEqual(metrics[0]["resetSeconds"] as? Int, 0)
    XCTAssertTrue(StatusRenderer.humanReadable(snapshot: snapshot, now: now).contains("Weekly reset since the last successful refresh"))
    XCTAssertEqual(StatusTemplate.render("{remaining}", snapshot: snapshot, kind: nil, separator: "", now: now), "60%")
  }

  func testFailureOnlyNamedRowsAndPriorityUseProviderAndAccountKey() throws {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage("shared")], failures: [
      ProviderFailure(accountID: "shared", provider: .openAI, kind: .network, message: "offline", title: "Work"),
      ProviderFailure(accountID: "shared", provider: .openAI, kind: .auth, message: "expired", title: "Work")
    ])
    let json = try object(snapshot)
    let accounts = try XCTUnwrap(json["accounts"] as? [[String: Any]])
    XCTAssertEqual(accounts.count, 2)
    XCTAssertEqual(accounts[0]["failed"] as? Bool, false)
    XCTAssertEqual(accounts[1]["name"] as? String, "Work")
    XCTAssertEqual(accounts[1]["errorKind"] as? String, "auth")
    XCTAssertTrue(accounts[1]["remainingPercent"] is NSNull)
    XCTAssertEqual(accounts[1]["lastKnown"] as? Bool, false)
    XCTAssertNil(accounts[1]["fetchedAt"])
    XCTAssertEqual(StatusTemplate.render("{name}:{class}", snapshot: snapshot, kind: nil, separator: ";", now: now), "shared:ok;Work:error")
  }

  func testStaleClassIsSharedWithTemplateAndCadenceMetadata() throws {
    for (interval, expected) in [(nil, "warning"), (180, "ok")] as [(Int?, String)] {
      let snapshot = QuotaSnapshot(generatedAt: now, providers: [usage("old", age: 10_800)], failures: [], refreshIntervalMinutes: interval)
      XCTAssertEqual(try object(snapshot)["class"] as? String, expected)
      XCTAssertEqual(StatusTemplate.render("{class}", snapshot: snapshot, kind: nil, separator: "", now: now), expected)
    }
    let empty = try object(.init(generatedAt: now, providers: [], failures: []))
    XCTAssertEqual(empty["text"] as? String, "LLimit: no accounts")
    XCTAssertFalse((empty["tooltip"] as? String)?.hasSuffix("\n") == true)
  }

  func testLiveCountdownsAreAdditiveAndLegacyFallbackIsTrimmed() {
    var metric = UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 40, resetAt: now.addingTimeInterval(3_600), resetIn: "99h")
    let first = StatusRenderer.metricObject(metric, now: now)
    XCTAssertEqual(first["resetSeconds"] as? Int, 3_600)
    XCTAssertEqual(first["resetIn"] as? String, "1h")
    XCTAssertEqual(first["resetAt"] as? String, "2023-11-14T23:13:20Z")
    XCTAssertEqual(StatusRenderer.metricObject(metric, now: now.addingTimeInterval(60))["resetSeconds"] as? Int, 3_540)
    let due = StatusRenderer.metricObject(metric, now: now.addingTimeInterval(3_600))
    XCTAssertNil(due["resetIn"])
    XCTAssertEqual(due["resetSeconds"] as? Int, 0)
    metric.resetAt = nil
    metric.resetIn = " 3h "
    XCTAssertEqual(StatusRenderer.metricObject(metric, now: now)["resetIn"] as? String, "3h")
    metric.resetIn = " "
    XCTAssertNil(StatusRenderer.metricObject(metric, now: now)["resetIn"])
  }

  func testErrorTextIsBoundedPlainAndPreservesComparisons() {
    let body = "HTTP 502: <!DOCTYPE html><style>color: red</style><title>Bad Gateway</title>\u{1B}[31mnginx\u{7}%{A1:bad:}" + String(repeating: " filler", count: 60)
    let text = StatusRenderer.sanitizedErrorText(body)
    XCTAssertTrue(text.hasPrefix("HTTP 502: Bad Gateway nginx % {"))
    XCTAssertLessThanOrEqual(text.count, 160)
    for forbidden in ["<", ">", "color", "\u{1B}", "\u{7}", "%{"] { XCTAssertFalse(text.contains(forbidden)) }
    XCTAssertEqual(StatusRenderer.sanitizedErrorText("limit < 5 and > 2"), "limit < 5 and > 2")
    XCTAssertEqual(StatusRenderer.sanitizedErrorText(String(repeating: " ", count: StatusRenderer.maximumScannedErrorLength) + "late"), "")
    XCTAssertEqual(StatusRenderer.sanitizedErrorText("HTTP 503 " + String(repeating: "<style>", count: 20_000)), "HTTP 503")
    XCTAssertEqual(StatusRenderer.sanitizedErrorText(String(repeating: "x", count: 155) + " <bold < 5 ok"), String(repeating: "x", count: 155) + "…")
  }

  func testCombiningCharactersCannotBypassErrorScanAndDisplayBounds() {
    let message = "e" + String(repeating: "\u{0301}", count: 20_000)
    XCTAssertLessThanOrEqual(StatusRenderer.sanitizedErrorText(message).unicodeScalars.count, StatusRenderer.maximumErrorLength)
  }

  func testCompactAmountAndFailureSummaryDoNotInventPercentages() {
    let balance = ProviderUsage(accountID: "v", provider: .venice, title: "Venice",
                                metrics: [UsageMetric(id: "balance", label: "Balance", remainingAmount: 4.25, usedDisplay: "$4.25")], fetchedAt: now)
    var snapshot = QuotaSnapshot(generatedAt: now, providers: [balance], failures: [])
    XCTAssertEqual(StatusRenderer.compactLine(snapshot: snapshot, now: now), "Venice:Balance $4.25")
    let key = balance.accountKey
    XCTAssertEqual(StatusRenderer.accountQuotaSummary(for: key, snapshot: snapshot, now: now), "$4.25")
    snapshot.failures.append(.init(accountID: "v", provider: .venice, kind: .auth, message: "expired"))
    XCTAssertEqual(StatusRenderer.accountQuotaSummary(for: key, snapshot: snapshot, now: now), "refresh failed (auth); last known $4.25")
  }
}
