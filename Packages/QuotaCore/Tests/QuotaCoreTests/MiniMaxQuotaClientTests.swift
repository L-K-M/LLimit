import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MiniMaxQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)
  private let key = "minimax-plan-fixture"

  private var configuration: ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: "my-plan", provider: .minimax,
      displayName: "My M Plan", isEnabled: true,
      credentials: [CredentialField.minimaxAPIKey: key])
  }

  private func bucket(name: String = "general") -> [String: Any] {
    ["model_name": name,
     "start_time": 1_790_000_000_000, "end_time": 1_790_018_000_000,
     "remains_time": 18_000_000,
     "weekly_start_time": 1_789_758_800_000, "weekly_end_time": 1_790_363_600_000,
     "weekly_remains_time": 363_600_000,
     "current_interval_status": 1, "current_weekly_status": 1,
     "current_interval_remaining_percent": 75, "current_weekly_remaining_percent": 40,
     "current_interval_total_count": 1000, "current_interval_usage_count": 250,
     "current_weekly_total_count": 10000, "current_weekly_usage_count": 4000]
  }

  private func body(_ buckets: [[String: Any]], status: Int? = 0) throws -> String {
    var object: [String: Any] = ["model_remains": buckets]
    if let status { object["base_resp"] = ["status_code": status, "status_msg": key] }
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  private func fetch(_ buckets: [[String: Any]]) async throws -> ProviderUsage {
    try await MiniMaxQuotaClient(httpClient: MiniMaxHTTP(body: body(buckets)))
      .fetchUsage(configuration: configuration, now: now)
  }

  func testFetchesQuotaWithBearerKeyAndServerResetTimes() async throws {
    let http = MiniMaxHTTP(body: try body([bucket()]))
    var config = configuration
    config.credentials[CredentialField.minimaxAPIKey] = " \(key)\n"
    let usage = try await MiniMaxQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)
    XCTAssertEqual(usage.accountID, "my-plan")
    XCTAssertEqual(usage.provider, .minimax)
    XCTAssertEqual(usage.title, "My M Plan")
    XCTAssertEqual(usage.subtitle, "M Plan")
    XCTAssertEqual(usage.metrics.map(\.id), ["general-interval", "general-weekly"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [75, 40])
    // Interval counts are consumed; weekly counts are remaining. The explicit
    // percentages resolve each independently, as in the official mmx CLI.
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["250", "6000"])
    XCTAssertEqual(usage.metrics.map(\.totalDisplay), ["1000", "10000"])
    XCTAssertEqual(usage.metrics.map(\.windowSeconds), [18000, 604800])
    XCTAssertEqual(usage.metrics.map(\.resetAt), [Date(timeIntervalSince1970: 1_790_018_000), Date(timeIntervalSince1970: 1_790_363_600)])
    XCTAssertNotNil(usage.metrics[0].resetIn)
    XCTAssertEqual(usage.maxUsagePercent, 60)
    XCTAssertNil(usage.warning)
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["general-interval", "general-weekly"])
    XCTAssertEqual(usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }, [.session, .weekly])
    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://www.minimax.io/v1/token_plan/remains")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.httpBody)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(usage), as: UTF8.self).contains(key))
  }

  func testUsesPercentagesWithZeroOrContradictoryCounts() async throws {
    var model = bucket()
    model["current_interval_total_count"] = 0
    model["current_interval_usage_count"] = 0
    model["current_weekly_usage_count"] = 10
    let usage = try await fetch([model])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [75, 40])
    XCTAssertTrue(usage.metrics.allSatisfy { $0.usedDisplay == nil && $0.totalDisplay == nil })
  }

  func testLegacyCountsMeanRemainingWhenPercentIsAbsent() async throws {
    var model = bucket()
    model.removeValue(forKey: "current_interval_remaining_percent")
    model.removeValue(forKey: "current_weekly_remaining_percent")
    let usage = try await fetch([model])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [25, 40])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["750", "6000"])
  }

  func testIncludesEveryBucketWithStableIDsAndReportedDurations() async throws {
    var video = bucket(name: "video")
    video["end_time"] = 1_790_086_400_000
    let first = try await fetch([video, bucket()])
    let reordered = try await fetch([bucket(), video])
    XCTAssertEqual(first.metrics, reordered.metrics)
    XCTAssertEqual(first.metrics.map(\.id), ["general-interval", "general-weekly", "video-interval", "video-weekly"])
    XCTAssertEqual(QuotaWindowKind.classify(metricID: first.metrics[2].id, label: first.metrics[2].label), .daily)
    XCTAssertEqual(first.metrics[2].windowSeconds, 86400)
    XCTAssertEqual(primaryLimitSlot(for: first.metrics)?.kind, .weekly)
  }

  func testUnlimitedAndUnavailableBucketsAreDifferent() async throws {
    var unlimited = bucket()
    unlimited["current_weekly_status"] = 3
    unlimited.removeValue(forKey: "current_weekly_remaining_percent")
    var unavailable = bucket(name: "video")
    unavailable["current_interval_status"] = 3
    unavailable["current_weekly_status"] = 3
    unavailable["current_interval_total_count"] = 0
    unavailable["current_weekly_total_count"] = 0
    let usage = try await fetch([unlimited, unavailable])
    XCTAssertTrue(usage.metrics[1].isUnlimited)
    XCTAssertNil(usage.metrics[1].remainingPercent)
    XCTAssertFalse(usage.metrics[2].isUnlimited)
    XCTAssertNil(usage.metrics[2].remainingPercent)
    XCTAssertEqual(usage.metrics[2].usageLine, "Not included in plan")
    await assertFailure(.api) { try await self.fetch([unavailable]) }
  }

  func testBoostUsesRemainingPercentageWithoutExceedingChartBounds() async throws {
    var model = bucket()
    model["weekly_boost_permille"] = 1500
    var usage = try await fetch([model])
    XCTAssertEqual(usage.metrics[1].remainingPercent, 60)
    model["current_weekly_remaining_percent"] = 100
    usage = try await fetch([model])
    XCTAssertEqual(usage.metrics[1].remainingPercent, 100)
    XCTAssertEqual(usage.metrics[1].detail, "150% of base quota remaining")
    XCTAssertEqual(usage.maxUsagePercent, 25)
  }

  func testExhaustedStatusDoesNotMasqueradeAsPositiveRemaining() async throws {
    var model = bucket()
    model["current_interval_status"] = 2
    let usage = try await fetch([model])
    XCTAssertEqual(usage.metrics[0].remainingPercent, 0)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "1000")
    XCTAssertEqual(usage.metrics[0].detail, "Limit reached")
    XCTAssertEqual(usage.maxUsagePercent, 100)
    XCTAssertEqual(usage.warning, "High usage")
  }

  func testCountdownsAreMillisecondsAndMissingStartDoesNotInventDuration() async throws {
    var model = bucket()
    for name in ["start_time", "end_time", "weekly_start_time", "weekly_end_time"] { model.removeValue(forKey: name) }
    let usage = try await fetch([model])
    XCTAssertEqual(usage.metrics[0].resetAt, now.addingTimeInterval(18000))
    XCTAssertEqual(usage.metrics[1].resetAt, now.addingTimeInterval(363600))
    XCTAssertTrue(usage.metrics.allSatisfy { $0.windowSeconds == nil })
  }

  func testAcceptsOfficialSDKResponseWithoutBaseResp() async throws {
    let usage = try await MiniMaxQuotaClient(httpClient: MiniMaxHTTP(body: body([bucket()], status: nil)))
      .fetchUsage(configuration: configuration, now: now)
    XCTAssertEqual(usage.metrics.count, 2)
  }

  func testRejectsMalformedOrIncompleteResponses() async throws {
    for invalid in [#"{}"#, #"{"base_resp":{"status_code":0},"model_remains":[]}"#,
                    #"{"model_remains":[false]}"#, "<html>\(key)</html>"] {
      await assertFailure(.decoding) {
        try await MiniMaxQuotaClient(httpClient: MiniMaxHTTP(body: invalid)).fetchUsage(configuration: self.configuration, now: self.now)
      }
    }
    for (field, value) in [("current_weekly_remaining_percent", -1), ("current_weekly_remaining_percent", 101),
                           ("current_interval_status", 4), ("weekly_boost_permille", -1), ("end_time", -1)] {
      var model = bucket()
      model[field] = value
      await assertFailure(.decoding) { try await self.fetch([model]) }
    }
    await assertFailure(.decoding) { try await self.fetch([self.bucket(), self.bucket()]) }
  }

  func testSanitizesHTTPBusinessAndTransportErrors() async throws {
    for (status, kind) in [(401, QuotaErrorKind.auth), (403, .auth), (429, .rateLimit), (500, .api)] {
      await assertFailure(kind) {
        try await MiniMaxQuotaClient(httpClient: MiniMaxHTTP(status: status, body: self.key))
          .fetchUsage(configuration: self.configuration, now: self.now)
      }
    }
    for (code, kind) in [(1004, QuotaErrorKind.auth), (2062, .api)] {
      await assertFailure(kind) {
        try await MiniMaxQuotaClient(httpClient: MiniMaxHTTP(body: self.body([], status: code)))
          .fetchUsage(configuration: self.configuration, now: self.now)
      }
    }
    await assertFailure(.network) {
      try await MiniMaxQuotaClient(httpClient: FailingMiniMaxHTTP())
        .fetchUsage(configuration: self.configuration, now: self.now)
    }
  }

  func testInvalidKeysDoNotMakeRequests() async throws {
    for value in ["", " \n", "key value", "key\nvalue", "key\u{0000}value"] {
      var config = configuration
      config.credentials = [CredentialField.minimaxAPIKey: value]
      let http = MiniMaxHTTP(body: "{}")
      await assertFailure(.notConfigured) {
        try await MiniMaxQuotaClient(httpClient: http).fetchUsage(configuration: config, now: self.now)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testLiveCoordinatorRegistersMiniMaxAndKeepsLastGoodOnFailure() async throws {
    let good = await QuotaCoordinator.live(httpClient: MiniMaxHTTP(body: try body([bucket()])))
      .refresh(configurations: [configuration], now: now)
    XCTAssertEqual(good.providers.count, 1)
    let failed = await QuotaCoordinator.live(httpClient: MiniMaxHTTP(body: "{}"))
      .refresh(configurations: [configuration], now: now.addingTimeInterval(60), previousSnapshot: good)
    XCTAssertEqual(failed.mergingStaleUsage(from: good).providers, good.providers)
    XCTAssertEqual(failed.failures.first?.kind, .decoding)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(failed), as: UTF8.self).contains(key))
  }

  func testLegacyUnknownWeeklyWindowPreservesValidInterval() async throws {
    var model = bucket()
    model.removeValue(forKey: "current_weekly_remaining_percent")
    model.removeValue(forKey: "current_weekly_status")
    model["current_weekly_total_count"] = 0
    model["current_weekly_usage_count"] = 0
    let usage = try await fetch([model])
    XCTAssertEqual(usage.metrics[0].remainingPercent, 75)
    XCTAssertNil(usage.metrics[1].remainingPercent)
    XCTAssertFalse(usage.metrics[1].isUnlimited)
    XCTAssertEqual(usage.metrics[1].detail, "Quota not reported")
  }

  func testExhaustedStatusWorksWithoutCountsOrPercent() async throws {
    var model = bucket()
    model["current_interval_status"] = 2
    for field in ["current_interval_remaining_percent", "current_interval_usage_count", "current_interval_total_count"] {
      model.removeValue(forKey: field)
    }
    let usage = try await fetch([model])
    XCTAssertEqual(usage.metrics[0].remainingPercent, 0)
  }

  func testTransportCancellationRemainsCancellation() async {
    for error in [CancellationError(), URLError(.cancelled)] as [any Error & Sendable] {
      do {
        _ = try await MiniMaxQuotaClient(httpClient: FailingMiniMaxHTTP(error: error))
          .fetchUsage(configuration: configuration, now: now)
        XCTFail("Expected cancellation")
      } catch is CancellationError {
      } catch {
        XCTFail("Expected cancellation, got \(type(of: error))")
      }
    }
  }

  private func assertFailure(_ kind: QuotaErrorKind, operation: () async throws -> ProviderUsage) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(kind)")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind)
      XCTAssertFalse(error.message.contains(key))
    } catch {
      XCTFail("Expected a sanitized provider error: \(type(of: error))")
    }
  }
}

private actor MiniMaxHTTP: HTTPClient {
  let status: Int
  let body: String
  private(set) var requests: [URLRequest] = []
  init(status: Int = 200, body: String) { self.status = status; self.body = body }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

private struct FailingMiniMaxHTTP: HTTPClient {
  var error: any Error & Sendable = ProviderClientError(kind: .network, message: "minimax-plan-fixture")
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw error
  }
}
