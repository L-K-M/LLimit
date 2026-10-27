import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunStatusTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let fixtureToken = "fixture-token"
  private let fixtureWebID = "fixture-device"

  private func configuration(token: String = "fixture-token", webID: String = "fixture-device") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "stepfun-personal", provider: .stepFun, displayName: "StepFun",
      isEnabled: true,
      credentials: [
        CredentialField.stepFunSessionToken: token,
        CredentialField.stepFunWebID: webID
      ]
    )
  }

  private func snapshot(body: String) async throws -> QuotaSnapshot {
    let http = StepFunStatusHTTP(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    return QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
  }

  private func object(_ snapshot: QuotaSnapshot) throws -> [String: Any] {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  // MARK: - Monthly subscription credits in waybar JSON

  func testMonthlySubscriptionCreditsRenderInWaybarJSON() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"subscription_credit_reset_time":"1700083200"}}"#
    let snapshot = try await snapshot(body: body)
    let json = try object(snapshot)

    XCTAssertEqual(json["text"] as? String, "StepFun 75%")
    XCTAssertEqual(json["percentage"] as? Int, 75)
    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["provider"] as? String, "stepfun")
    XCTAssertEqual(account["id"] as? String, "stepfun-personal")
    XCTAssertEqual(account["remainingPercent"] as? Int, 75)

    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 1)
    let metric = try XCTUnwrap(metrics.first)
    XCTAssertEqual(metric["id"] as? String, "monthly-credits")
    XCTAssertEqual(metric["label"] as? String, "Monthly plan credits")
    XCTAssertEqual(metric["remainingPercent"] as? Int, 75)
    XCTAssertEqual(metric["window"] as? String, "monthly")
  }

  // MARK: - No secrets in output

  func testNoSecretsInWaybarJSON() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let snapshot = try await snapshot(body: body)
    let waybar = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)

    XCTAssertFalse(waybar.contains(fixtureToken))
    XCTAssertFalse(waybar.contains(fixtureWebID))
    XCTAssertFalse(waybar.contains("Oasis-Token"))
    XCTAssertFalse(waybar.contains("Oasis-Webid"))
  }

  func testNoSecretsInSerializedSnapshot() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let snapshot = try await snapshot(body: body)
    let serialized = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

    XCTAssertFalse(serialized.contains(fixtureToken))
    XCTAssertFalse(serialized.contains(fixtureWebID))
  }

  // MARK: - Human readable output

  func testHumanReadableShowsMonthlyCredits() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let snapshot = try await snapshot(body: body)
    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: now)

    XCTAssertTrue(human.contains("StepFun"))
    XCTAssertTrue(human.contains("75%"))
    XCTAssertFalse(human.contains(fixtureToken))
  }

  // MARK: - Compact line

  func testCompactLineShowsProviderAndPercent() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let snapshot = try await snapshot(body: body)
    let compact = StatusRenderer.compactLine(snapshot: snapshot, now: now)

    XCTAssertTrue(compact.contains("StepFun"))
    XCTAssertTrue(compact.contains("75%"))
  }

  // MARK: - Top-up and subscription both appear

  func testTopUpAndSubscriptionBothAppearInJSON() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"credit_buckets":[{"type":2,"credit_total":400,"credit_residual":100,"expire_at":"1800000000"}]}}"#
    let snapshot = try await snapshot(body: body)
    let json = try object(snapshot)

    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 2)

    let sub = try XCTUnwrap(metrics.first { $0["id"] as? String == "monthly-credits" })
    XCTAssertEqual(sub["remainingPercent"] as? Int, 75)

    let topup = try XCTUnwrap(metrics.first { $0["id"] as? String == "topup-credits" })
    XCTAssertEqual(topup["remainingPercent"] as? Int, 25)
  }

  // MARK: - Legacy metrics render correctly

  func testLegacyMetricsRenderInJSON() async throws {
    let body = #"{"status":"CODE_OK","plan_family":1,"five_hour_usage_left_rate":0.5,"weekly_usage_left_rate":0.2}"#
    let snapshot = try await snapshot(body: body)
    let json = try object(snapshot)

    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 2)

    let fiveHour = try XCTUnwrap(metrics.first { $0["id"] as? String == "five-hour" })
    XCTAssertEqual(fiveHour["remainingPercent"] as? Int, 50)

    let weekly = try XCTUnwrap(metrics.first { $0["id"] as? String == "weekly" })
    XCTAssertEqual(weekly["remainingPercent"] as? Int, 20)
    XCTAssertEqual(weekly["window"] as? String, "weekly")
  }

  // MARK: - Reset time preserved in JSON

  func testResetTimePreservedInJSON() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"subscription_credit_reset_time":"1700083200"}}"#
    let snapshot = try await snapshot(body: body)
    let json = try object(snapshot)

    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    let metric = try XCTUnwrap(metrics.first)
    XCTAssertNotNil(metric["resetAt"])
    XCTAssertNotNil(metric["resetSeconds"])
  }
}

// MARK: - HTTP Stub

private actor StepFunStatusHTTP: HTTPClient {
  private let body: String
  private(set) var requests: [URLRequest] = []

  init(body: String) { self.body = body }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    return try await data(for: request)
  }
}
