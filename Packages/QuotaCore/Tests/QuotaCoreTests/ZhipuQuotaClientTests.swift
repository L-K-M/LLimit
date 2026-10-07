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

  func testWeeklyTokenCapsHaveStableIDsAndTakeTheSecondRing() async throws {
    let session = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":40,"nextResetTime":1700010000000}"#
    let weekly = #"{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":85,"nextResetTime":1700300000000}"#
    for provider in [QuotaProvider.zai, .zhipu] {
      for entries in [[session, weekly], [weekly, session]] {
        let usage = try await fetch(tokenPayload(entries), provider: provider)
        XCTAssertEqual(Set(usage.metrics.map(\.id)), ["tokens", "tokens-weekly", "mcp"])
        XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["tokens", "tokens-weekly"])
        let metric = try XCTUnwrap(usage.metrics.first { $0.id == "tokens-weekly" })
        XCTAssertEqual(metric.label, "Weekly token limit")
        XCTAssertEqual(metric.remainingPercent, 15)
        XCTAssertEqual(metric.resetAt, Date(timeIntervalSince1970: 1_700_300_000))
        XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .weekly)
        XCTAssertEqual(usage.maxUsagePercent, 85)
        XCTAssertEqual(usage.warning, "High usage")
      }
    }
  }

  func testUnknownCodesRemainNeutralAndMalformedKnownWindowsFail() async throws {
    for (unit, id) in [("5", "tokens-u5-n1"), ("3", "tokens-u3-n1")] {
      let usage = try await fetch(tokenPayload([#"{"type":"TOKENS_LIMIT","unit":\#(unit),"number":1,"percentage":90}"#]))
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertEqual(metric.id, id)
      XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .other)
    }
    let valid = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":40}"#
    let malformed = #"{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":"n/a"}"#
    let duplicateMalformed = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":"n/a"}"#
    for entries in [[valid, malformed], [malformed, valid], [valid, duplicateMalformed]] {
      do {
        _ = try await fetch(tokenPayload(entries))
        XCTFail("Malformed known windows must not disappear")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .decoding) }
    }
  }

  func testMalformedDescriptorsFailInsteadOfConflatingTokenCaps() async {
    let descriptorPairs = [
      (#""unit":"HOUR","number":1"#, #""unit":"WEEK","number":1"#),
      (#""unit":3.51,"number":1"#, #""unit":3.52,"number":1"#),
      (#""unit":5,"number":1.51"#, #""unit":5,"number":1.52"#),
      (#""unit":"3invalid","number":5"#, #""unit":3,"number":"5invalid""#),
      (#""unit":true,"number":1"#, #""unit":{},"number":1"#)
    ]
    for provider in [QuotaProvider.zai, .zhipu] {
      for (first, second) in descriptorPairs {
        let entries = [first, second].map { #"{"type":"TOKENS_LIMIT",\#($0),"percentage":40}"# }
        for orderedEntries in [entries, entries.reversed().map { $0 }] {
          do {
            _ = try await fetch(tokenPayload(orderedEntries), provider: provider)
            XCTFail("Malformed descriptors must fail instead of dropping a token cap")
          } catch let error as ProviderClientError {
            XCTAssertEqual(error.kind, .decoding)
            XCTAssertFalse(error.message.contains("3invalid"))
            XCTAssertFalse(error.message.contains("5invalid"))
            XCTAssertFalse(error.message.contains("HOUR"))
          } catch { XCTFail("Unexpected error: \(error)") }
        }
      }
    }
  }

  func testKnownAndNeutralDescriptorsPreserveTheirIDsAndLabels() async throws {
    let descriptors = [
      (#""unit":"3","number":"5""#, "tokens", "5-hour token limit"),
      (#""unit":3.0,"number":5.0"#, "tokens", "5-hour token limit"),
      (#""unit":6,"number":1"#, "tokens-weekly", "Weekly token limit"),
      (#""unit":3,"number":7"#, "tokens-u3-n7", "Token limit (unit 3, number 7)"),
      (#""unit":6,"number":2"#, "tokens-u6-n2", "Token limit (unit 6, number 2)"),
      (#""unit":5"#, "tokens-u5", "Token limit (unit 5)"),
      (#""unit":null"#, "tokens", "Token limit"),
      // Adjacent large integers must not acquire the same rounded identity.
      (#""unit":9007199254740992,"number":1"#, "tokens-u9007199254740992-n1", "Token limit (unit 9007199254740992, number 1)"),
      (#""unit":9007199254740993,"number":1"#, "tokens-u9007199254740993-n1", "Token limit (unit 9007199254740993, number 1)")
    ]
    for (descriptor, id, label) in descriptors {
      let usage = try await fetch(tokenPayload([#"{"type":"TOKENS_LIMIT",\#(descriptor),"percentage":40}"#]))
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertEqual(metric.id, id)
      XCTAssertEqual(metric.label, label)
      if id.hasPrefix("tokens-u") {
        XCTAssertEqual(QuotaWindowKind.classify(metricID: id, label: label), .other)
      }
    }
  }

  func testReportedRetryGuidanceReachesTheFailureDeadline() async {
    let endpoint = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    let configuration = ProviderRuntimeConfiguration(provider: .zai, isEnabled: true, credentials: [CredentialField.zaiAPIKey: Self.apiKey])
    for (header, delay) in [("120", 120.0), ("Tue, 14 Nov 2023 22:18:20 GMT", 300.0),
                            ("malformed", nil), (nil, nil)] as [(String?, TimeInterval?)] {
      let http = MockZhipuHTTP(status: 429, body: "secret response", expectedKey: Self.apiKey,
                              headers: header.map { ["Retry-After": $0] } ?? [:])
      let client = ZhipuQuotaClient(provider: .zai, endpoint: endpoint, accountLabel: "Z.ai", httpClient: http)
      let snapshot = await QuotaCoordinator(clients: [client]).refresh(configurations: [configuration], now: now)
      XCTAssertEqual(snapshot.failures.first?.kind, .rateLimit)
      XCTAssertEqual(snapshot.failures.first?.retryAt, delay.map { now.addingTimeInterval($0) })
      XCTAssertFalse(snapshot.failures.first?.message.contains("secret response") ?? true)
    }
  }

  func testSuccessMarkersAreAuthoritativeAnd429IsRateLimit() async throws {
    let base = payload(planReset: nil)
    let noCode = base.replacingOccurrences(of: "\"code\": 200,", with: "")
    XCTAssertNotEqual(noCode, base, "Missing-code fixture replacement must match")
    let noCodeUsage = try await fetch(noCode)
    XCTAssertEqual(noCodeUsage.metrics.first?.remainingPercent, 60)
    let codeOnly = base.replacingOccurrences(of: "\"success\": true,", with: "")
    XCTAssertNotEqual(codeOnly, base, "Code-only fixture replacement must match")
    let codeOnlyUsage = try await fetch(codeOnly)
    XCTAssertEqual(codeOnlyUsage.metrics.first?.remainingPercent, 60)
    let rejected = base.replacingOccurrences(of: "\"success\": true", with: "\"success\": false")
    XCTAssertNotEqual(rejected, base, "Failure fixture replacement must match")
    do {
      _ = try await fetch(rejected)
      XCTFail("Explicit failure must override code 200")
    } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .api) }

    let client = ZhipuQuotaClient(provider: .zai, endpoint: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!, accountLabel: "Z.ai", httpClient: MockZhipuHTTP(status: 429, body: "secret response", expectedKey: Self.apiKey))
    do {
      _ = try await client.fetchUsage(configuration: ProviderRuntimeConfiguration(provider: .zai, isEnabled: true, credentials: [CredentialField.zaiAPIKey: Self.apiKey]), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
      XCTAssertFalse(error.message.contains("secret response"))
    }
  }

  private func tokenPayload(_ entries: [String]) -> String {
    #"{"success":true,"code":200,"data":{"limits":[\#(entries.joined(separator: ",")),{"type":"TIME_LIMIT","percentage":25,"currentValue":50,"usage":200}]}}"#
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
  var headers: [String: String] = [:]

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/api/monitor/usage/quota/limit")
    // The key goes in bare, with no "Bearer " prefix.
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedKey)

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    return (body.data(using: .utf8)!, response)
  }
}
