import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MiniMaxStatusTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let key = "minimax-status-fixture"

  private func snapshot(overrides: [String: Any] = [:]) async throws -> QuotaSnapshot {
    var bucket: [String: Any] = [
      "model_name": "general",
      "start_time": 1_699_996_400_000, "end_time": 1_700_014_400_000,
      "weekly_start_time": 1_699_740_800_000, "weekly_end_time": 1_700_345_600_000,
      "current_interval_total_count": 100, "current_interval_usage_count": 80,
      "current_interval_remaining_percent": 80, "current_interval_status": 1,
      "current_weekly_total_count": 100, "current_weekly_usage_count": 55,
      "current_weekly_remaining_percent": 45, "current_weekly_status": 1
    ]
    bucket.merge(overrides) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: [
      "base_resp": ["status_code": 0], "model_remains": [bucket]
    ])
    let http = MiniMaxStatusHTTP(data: data)
    let configuration = ProviderRuntimeConfiguration(
      accountID: "personal-minimax", provider: .minimax, displayName: "MiniMax",
      isEnabled: true, credentials: [CredentialField.minimaxAPIKey: key]
    )
    let usage = try await MiniMaxQuotaClient(httpClient: http).fetchUsage(configuration: configuration, now: now)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    return QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])
  }

  private func object(_ snapshot: QuotaSnapshot) throws -> [String: Any] {
    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  func testBoundedPlanStatusPreservesBothWindowsAndServerResets() async throws {
    let snapshot = try await snapshot()
    let json = try object(snapshot)
    XCTAssertEqual(json["text"] as? String, "MiniMax 45%")
    XCTAssertEqual(json["percentage"] as? Int, 45)
    XCTAssertEqual(json["class"] as? String, "ok")

    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    XCTAssertEqual(account["provider"] as? String, "minimax")
    XCTAssertEqual(account["id"] as? String, "personal-minimax")
    XCTAssertEqual(account["remainingPercent"] as? Int, 45)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 2)
    let interval = try XCTUnwrap(metrics.first { $0["id"] as? String == "general-interval" })
    let weekly = try XCTUnwrap(metrics.first { $0["id"] as? String == "general-weekly" })
    XCTAssertEqual(interval["remainingPercent"] as? Int, 80)
    XCTAssertEqual(interval["window"] as? String, "session")
    XCTAssertEqual(interval["usageLine"] as? String, "20 / 100")
    XCTAssertEqual(interval["resetAt"] as? String, "2023-11-15T02:13:20Z")
    XCTAssertEqual(interval["resetIn"] as? String, "4h")
    XCTAssertEqual(interval["resetSeconds"] as? Int, 14_400)
    XCTAssertEqual(weekly["remainingPercent"] as? Int, 45)
    XCTAssertEqual(weekly["window"] as? String, "weekly")
    XCTAssertEqual(weekly["usageLine"] as? String, "55 / 100")
    XCTAssertEqual(weekly["resetAt"] as? String, "2023-11-18T22:13:20Z")
    XCTAssertEqual(weekly["resetSeconds"] as? Int, 345_600)
    let resets = try XCTUnwrap(json["resets"] as? [[String: Any]])
    XCTAssertEqual(resets.map { $0["metricID"] as? String }, ["general-interval", "general-weekly"])

    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: now)
    XCTAssertTrue(human.contains("General 5-hour limit 80% left (resets in 4h)"))
    XCTAssertTrue(human.contains("General weekly 45% left"))
    XCTAssertEqual(StatusRenderer.compactLine(snapshot: snapshot, now: now), "MiniMax:45%")
    XCTAssertFalse(StatusRenderer.waybarJSON(snapshot: snapshot, now: now).contains(CredentialField.minimaxAPIKey))
    for output in [human, StatusRenderer.waybarJSON(snapshot: snapshot, now: now),
                   String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)] {
      XCTAssertFalse(output.contains(key))
      XCTAssertFalse(output.contains("credentials"))
    }
  }

  func testAllUnlimitedStatusDoesNotInventAZeroOrFullPercentage() async throws {
    let snapshot = try await snapshot(overrides: [
      "current_interval_status": 3, "current_weekly_status": 3
    ])
    let json = try object(snapshot)
    XCTAssertEqual(json["text"] as? String, "MiniMax unlimited")
    XCTAssertEqual(json["class"] as? String, "ok")
    XCTAssertNil(json["percentage"])
    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    XCTAssertTrue(account["remainingPercent"] is NSNull)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 2)
    for metric in metrics {
      XCTAssertEqual(metric["unlimited"] as? Bool, true)
      XCTAssertEqual(metric["usageLine"] as? String, "Unlimited")
      XCTAssertNil(metric["remainingPercent"])
    }
    XCTAssertEqual(StatusRenderer.compactLine(snapshot: snapshot, now: now), "MiniMax:unlimited")
    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: now)
    XCTAssertTrue(human.contains("General 5-hour limit unlimited"))
    XCTAssertTrue(human.contains("General weekly unlimited"))
    XCTAssertFalse(human.contains("0%"))
    XCTAssertFalse(human.contains("100%"))
  }

  func testBoostedWeeklyDetailSurvivesTheJSONContract() async throws {
    let snapshot = try await snapshot(overrides: [
      "current_weekly_usage_count": 20, "current_weekly_remaining_percent": 80,
      "weekly_boost_permille": 1500
    ])
    let json = try object(snapshot)
    let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
    let metrics = try XCTUnwrap(account["metrics"] as? [[String: Any]])
    let weekly = try XCTUnwrap(metrics.first { $0["id"] as? String == "general-weekly" })
    XCTAssertEqual(weekly["remainingPercent"] as? Int, 100)
    XCTAssertEqual(weekly["detail"] as? String, "120% of base quota remaining")
    XCTAssertEqual(weekly["usageLine"] as? String, "20 / 100")
    XCTAssertEqual(account["remainingPercent"] as? Int, 80)
    XCTAssertEqual(json["percentage"] as? Int, 80)
  }
}

private actor MiniMaxStatusHTTP: HTTPClient {
  let data: Data
  private(set) var requests: [URLRequest] = []

  init(data: Data) { self.data = data }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
