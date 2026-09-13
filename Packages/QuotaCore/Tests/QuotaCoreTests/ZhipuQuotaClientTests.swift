import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ZhipuQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testZaiTokenWindowKeepsItsSessionClassification() async throws {
    let usage = try await fetch(payload(planReset: "2023-11-19T00:00:00Z"))

    let tokens = try XCTUnwrap(usage.metrics.first { $0.id == "tokens" })
    XCTAssertEqual(tokens.label, "Token limit")
    XCTAssertEqual(tokens.remainingPercent, 60)
    XCTAssertEqual(tokens.usageLine, "4.0M / 10.0M")
    // The label names no cadence, so the id has to carry it.
    XCTAssertEqual(QuotaWindowKind.classify(metricID: tokens.id, label: tokens.label), .session)
  }

  func testZhipuTokenWindowStillNamesItsDuration() async throws {
    let usage = try await fetch(payload(planReset: nil), provider: .zhipu)

    let tokens = try XCTUnwrap(usage.metrics.first { $0.id == "tokens" })
    XCTAssertEqual(tokens.label, "5-hour token limit")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: tokens.id, label: tokens.label), .session)
  }

  // The common shape: the TIME_LIMIT entry reports no reset of its own, so the
  // countdown tracks the plan renewal and lands nowhere near the 1st.
  func testMCPQuotaExplainsAPlanAnchoredReset() async throws {
    let usage = try await fetch(payload(planReset: "2023-11-19T00:00:00Z"))

    let mcp = try XCTUnwrap(usage.metrics.first { $0.id == "mcp" })
    XCTAssertEqual(mcp.label, "MCP monthly quota")
    XCTAssertEqual(mcp.remainingPercent, 75)
    XCTAssertEqual(mcp.usageLine, "50 / 200")
    XCTAssertEqual(try XCTUnwrap(mcp.resetAt), Date(timeIntervalSince1970: 1_700_352_000))
    XCTAssertEqual(
      mcp.detail,
      "A separate allowance from the token window. Resets when your plan period renews, not on the 1st."
    )
    XCTAssertEqual(QuotaWindowKind.classify(metricID: mcp.id, label: mcp.label), .monthly)
  }

  func testMCPQuotaPrefersAndExplainsItsOwnReportedReset() async throws {
    let usage = try await fetch(
      payload(timeLimitReset: "2023-11-25T00:00:00Z", planReset: "2023-11-19T00:00:00Z")
    )

    let mcp = try XCTUnwrap(usage.metrics.first { $0.id == "mcp" })
    XCTAssertEqual(try XCTUnwrap(mcp.resetAt), Date(timeIntervalSince1970: 1_700_870_400))
    XCTAssertEqual(mcp.detail, "A separate allowance from the token window, with its own reset.")
  }

  // Neither date is reported, so the countdown is LLimit's guess and the
  // dropdown has to say so rather than presenting it as provider data.
  func testMCPQuotaDisclosesAnAssumedReset() async throws {
    let usage = try await fetch(payload(planReset: nil))

    let mcp = try XCTUnwrap(usage.metrics.first { $0.id == "mcp" })
    // Pinned by calendar components rather than an epoch: `startOfNextMonth`
    // works in the runner's own time zone, which moves the exact instant by up
    // to a day either way. December 1st 2023 is the answer in every zone.
    let resetAt = try XCTUnwrap(mcp.resetAt)
    let components = Calendar(identifier: .gregorian)
      .dateComponents([.year, .month, .day, .hour], from: resetAt)
    XCTAssertEqual(components.year, 2023)
    XCTAssertEqual(components.month, 12)
    XCTAssertEqual(components.day, 1)
    XCTAssertEqual(components.hour, 0)
    XCTAssertEqual(
      mcp.detail,
      "A separate allowance from the token window. No reset date was reported, so the 1st of next month is assumed."
    )
  }

  /// Both endpoints are the ones `QuotaCoordinator.live()` registers: same path
  /// on two hosts, which is why one client serves both providers.
  private func fetch(_ body: String, provider: QuotaProvider = .zai) async throws -> ProviderUsage {
    let endpoint = provider == .zai
      ? "https://api.z.ai/api/monitor/usage/quota/limit"
      : "https://bigmodel.cn/api/monitor/usage/quota/limit"
    let client = ZhipuQuotaClient(
      provider: provider,
      endpoint: URL(string: endpoint)!,
      accountLabel: "Z.ai",
      httpClient: MockZhipuHTTP(status: 200, body: body, expectedKey: Self.apiKey)
    )
    let key = provider == .zai ? CredentialField.zaiAPIKey : CredentialField.zhipuAPIKey
    let configuration = ProviderRuntimeConfiguration(
      provider: provider,
      isEnabled: true,
      credentials: [key: Self.apiKey]
    )
    return try await client.fetchUsage(configuration: configuration, now: now)
  }

  private static let apiKey = "sk-zai"

  /// `currentValue` is the used count and `usage` the entitlement, matching the
  /// key precedence the client reads.
  private func payload(timeLimitReset: String? = nil, planReset: String?) -> String {
    let entryReset = timeLimitReset.map { ", \"resetTime\": \"\($0)\"" } ?? ""
    let dataReset = planReset.map { ", \"nextResetTime\": \"\($0)\"" } ?? ""
    return """
    {
      "success": true,
      "code": 200,
      "data": {
        "limits": [
          {"type": "TOKENS_LIMIT", "percentage": 40, "currentValue": 4000000, "usage": 10000000},
          {"type": "TIME_LIMIT", "percentage": 25, "currentValue": 50, "usage": 200\(entryReset)}
        ]\(dataReset)
      }
    }
    """
  }
}

/// Answers 200 with `body`, but first checks the request the client built. A
/// dropped credential header or a wrong path would otherwise 401 or 404 in
/// production while every parsing test here still passed.
private struct MockZhipuHTTP: HTTPClient {
  let status: Int
  let body: String
  let expectedKey: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/api/monitor/usage/quota/limit")
    // The key goes in bare, with no "Bearer " prefix.
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedKey)

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (body.data(using: .utf8)!, response)
  }
}
