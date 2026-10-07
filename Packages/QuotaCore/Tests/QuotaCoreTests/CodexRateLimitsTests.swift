import XCTest
@testable import QuotaCore

final class CodexRateLimitsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let configuration = ProviderRuntimeConfiguration(
    accountID: "llimit-account", provider: .openAI, displayName: "Work OpenAI", isEnabled: true, credentials: [:])

  func testLegacyResponseUsesExistingMetricIDsAndRealWindowDurations() throws {
    let usage = try decode(#"{"rateLimits":{"planType":"pro","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1700000600},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":1700007200}}}"#)
    XCTAssertEqual(usage.accountID, "llimit-account")
    XCTAssertEqual(usage.provider, .openAI)
    XCTAssertEqual(usage.title, "Work OpenAI")
    XCTAssertEqual(usage.subtitle, "pro")
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(usage.metrics.map(\.id), ["primary", "secondary"])
    XCTAssertEqual(usage.metrics.map(\.label), ["5-hour limit", "7-day limit"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [75, 20])
    XCTAssertEqual(usage.metrics.map(\.resetIn), ["10m", "2h"])
    XCTAssertEqual(usage.metrics[0].resetAt, now.addingTimeInterval(600))
    XCTAssertEqual(usage.maxUsagePercent, 80)
    XCTAssertNil(usage.warning)
  }

  func testMultiBucketResponseIsAuthoritativeAndStable() throws {
    let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"spark":{"limitName":"Codex Spark","planType":"pro","primary":{"usedPercent":40,"windowDurationMins":90},"secondary":{"usedPercent":3,"windowDurationMins":10080}},"codex":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300}},"daily":{"primary":{"usedPercent":75,"windowDurationMins":1440}}}}"#)
    XCTAssertEqual(usage.metrics.map(\.id), ["primary", "bucket.daily.primary", "bucket.spark.primary", "bucket.spark.secondary"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [90, 25, 60, 97])
    XCTAssertEqual(usage.metrics.map(\.label), ["5-hour limit", "1-day limit (daily)", "90-minute limit (spark)", "7-day limit (spark)"])
    XCTAssertEqual(usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }, [.session, .daily, .session, .weekly])
    XCTAssertEqual(usage.metrics[2].detail, "Codex Spark")
    XCTAssertEqual(usage.subtitle, "plus")
    XCTAssertEqual(usage.maxUsagePercent, 75)
  }

  func testMissingUsageOrResetDoesNotFabricateZero() throws {
    let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":null,"resetsAt":null},"secondary":{}}}"#)
    XCTAssertEqual(usage.metrics.map(\.label), ["Primary limit", "Secondary limit"])
    XCTAssertTrue(usage.metrics.allSatisfy { $0.remainingPercent == nil && $0.resetAt == nil && $0.resetIn == nil })
    XCTAssertNil(usage.maxUsagePercent)
    XCTAssertNil(usage.warning)
  }

  func testReportedWindowDurationsRemainAvailableForPace() throws {
    let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1700000600},"secondary":{"usedPercent":80,"resetsAt":1700007200}}}"#)
    XCTAssertEqual(usage.metrics.map(\.windowSeconds), [18_000, nil])

    let buckets = try decode(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":10080}},"spark":{"primary":{"usedPercent":40,"windowDurationMins":90}}}}"#)
    XCTAssertEqual(buckets.metrics.map(\.windowSeconds), [604_800, 5_400])
  }

  func testMissingWindowsRemainExplicitlyUnavailable() throws {
    for input in [#"{"rateLimits":{"primary":null,"secondary":null}}"#, #"{"rateLimits":{"primary":{"usedPercent":100}},"rateLimitsByLimitId":{}}"#] {
      let usage = try decode(input)
      XCTAssertEqual(usage.metrics.count, 1)
      XCTAssertEqual(usage.metrics[0].id, "empty")
      XCTAssertNil(usage.metrics[0].remainingPercent)
      XCTAssertNil(usage.maxUsagePercent)
      XCTAssertNil(usage.warning)
    }
  }

  func testNullMultiBucketViewFallsBackToLegacy() throws {
    let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":17}},"rateLimitsByLimitId":null}"#)
    XCTAssertEqual(usage.metrics[0].id, "primary")
    XCTAssertEqual(usage.metrics[0].remainingPercent, 83)
  }

  func testAvailableMultiBucketViewDoesNotDependOnUnusedLegacyFormat() throws {
    let usage = try decode(#"{"rateLimits":"obsolete","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":17}}}}"#)
    XCTAssertEqual(usage.metrics[0].remainingPercent, 83)
  }

  func testClampsReportedUsageToValidDisplayRange() throws {
    let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":-10},"secondary":{"usedPercent":150}}}"#)
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [100, 0])
    XCTAssertEqual(usage.maxUsagePercent, 100)
    XCTAssertEqual(usage.warning, "Rate limit reached")
  }

  func testReachedStateWithUnavailableUsageStillWarns() throws {
    let usage = try decode(#"{"rateLimits":{"rateLimitReachedType":"workspace_member_credits_depleted"}}"#)
    XCTAssertEqual(usage.warning, "Rate limit reached")
    XCTAssertNil(usage.maxUsagePercent)
  }

  func testPastResetDoesNotCreateNegativeCountdown() throws {
    let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":0,"resetsAt":1600000000}}}"#)
    XCTAssertEqual(usage.metrics[0].resetIn, "reset")
    XCTAssertEqual(usage.metrics[0].resetAt, Date(timeIntervalSince1970: 1_600_000_000))
  }

  func testLegacyNonCodexBucketRetainsItsIdentity() throws {
    let usage = try decode(#"{"rateLimits":{"limitId":"spark","primary":{"usedPercent":10,"windowDurationMins":300}}}"#)
    XCTAssertEqual(usage.metrics[0].id, "bucket.spark.primary")
    XCTAssertEqual(usage.metrics[0].label, "5-hour limit (spark)")
  }

  func testMalformedResponsesRejectInsteadOfShowingFabricatedUsage() throws {
    let inputs = [
      "sensitive invalid response", "[]", "{}", #"{"rateLimits":null}"#,
      #"{"rateLimits":{"primary":{"usedPercent":"sensitive"}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":true}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":1e400}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":0}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":-1}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":1.5}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":10,"resetsAt":-1}}}"#,
      #"{"rateLimits":{"primary":{"usedPercent":10,"resetsAt":1700000000.5}}}"#,
      #"{"rateLimitsByLimitId":{"":{}}}"#
    ]
    for input in inputs {
      XCTAssertThrowsError(try decode(input), input) {
        XCTAssertEqual($0 as? CodexRateLimitsError, .invalidResponse)
        XCTAssertFalse($0.localizedDescription.contains("sensitive"))
      }
    }
  }

  private func decode(_ input: String) throws -> ProviderUsage {
    try CodexRateLimits(data: Data(input.utf8)).usage(configuration: configuration, now: now)
  }
}
