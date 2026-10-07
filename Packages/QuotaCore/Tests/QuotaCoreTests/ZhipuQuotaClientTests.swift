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

  // The GLM Coding Plan sends one TOKENS_LIMIT entry per window, told apart
  // only by `unit` and `number`. Both orders must yield the same metrics, so
  // the ids and labels cannot depend on array position.
  func testCodingPlanReportsTheWeeklyTokenCapInEitherOrder() async throws {
    for provider in [QuotaProvider.zai, .zhipu] {
      for tokenLimits in [[Self.fiveHourEntry, Self.weeklyEntry], [Self.weeklyEntry, Self.fiveHourEntry]] {
        let usage = try await fetch(payload(tokenLimits: tokenLimits, planReset: nil), provider: provider)
        let context = "\(provider.rawValue) \(tokenLimits.first == Self.weeklyEntry ? "weekly first" : "5-hour first")"

        XCTAssertEqual(Set(usage.metrics.map(\.id)), ["tokens", "tokens-weekly", "mcp"], context)

        let session = try XCTUnwrap(usage.metrics.first { $0.id == "tokens" }, context)
        XCTAssertEqual(session.label, "5-hour token limit", context)
        XCTAssertEqual(session.remainingPercent, 60, context)
        XCTAssertEqual(session.usageLine, "4.0M / 10.0M", context)
        XCTAssertEqual(session.resetAt, Date(timeIntervalSince1970: 1_700_010_000), context)
        XCTAssertEqual(QuotaWindowKind.classify(metricID: session.id, label: session.label), .session, context)

        let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "tokens-weekly" }, context)
        XCTAssertEqual(weekly.label, "Weekly token limit", context)
        XCTAssertEqual(weekly.remainingPercent, 15, context)
        // The weekly entry carries no counts, so the line falls back to the
        // used percentage out of 100, as a count-less token entry always has.
        XCTAssertEqual(weekly.usageLine, "85 / 100", context)
        XCTAssertEqual(weekly.resetAt, Date(timeIntervalSince1970: 1_700_300_000), context)
        XCTAssertEqual(QuotaWindowKind.classify(metricID: weekly.id, label: weekly.label), .weekly, context)

        // The weekly cap is the fullest window, so it drives the warning.
        XCTAssertEqual(usage.maxUsagePercent, 85, context)
        XCTAssertEqual(usage.warning, "High usage", context)
        XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["tokens", "tokens-weekly"], context)
      }
    }
  }

  // No source documents other codes, so an unknown pair is shown under a
  // neutral id and label rather than a guessed cadence.
  func testUnknownTokenWindowCodesStayNeutral() async throws {
    let unknown = #"{"type": "TOKENS_LIMIT", "unit": 5, "number": 1, "percentage": 90}"#
    let usage = try await fetch(payload(tokenLimits: [Self.fiveHourEntry, unknown], planReset: nil))

    XCTAssertEqual(usage.metrics.map(\.id), ["tokens", "tokens-u5-n1", "mcp"])
    let metric = try XCTUnwrap(usage.metrics.first { $0.id == "tokens-u5-n1" })
    XCTAssertEqual(metric.label, "Token limit (unit 5, number 1)")
    XCTAssertEqual(metric.remainingPercent, 10)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .other)
    XCTAssertEqual(usage.maxUsagePercent, 90)
  }

  // A `unit` that is present but not a number is no known shape: it must not
  // take the legacy 5-hour identity, and its text is not echoed into the id
  // or label, where the classifier would read a word like "HOUR" as a cadence.
  func testNonNumericUnitIsUnrecognizedRatherThanLegacy() async throws {
    let textUnit = #"{"type": "TOKENS_LIMIT", "unit": "HOUR", "number": 5, "percentage": 70}"#
    let usage = try await fetch(payload(tokenLimits: [textUnit, Self.fiveHourEntry], planReset: nil))

    XCTAssertEqual(usage.metrics.map(\.id), ["tokens-uunknown-n5", "tokens", "mcp"])
    let unknown = try XCTUnwrap(usage.metrics.first { $0.id == "tokens-uunknown-n5" })
    XCTAssertEqual(unknown.label, "Token limit (unit unknown, number 5)")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: unknown.id, label: unknown.label), .other)

    let session = try XCTUnwrap(usage.metrics.first { $0.id == "tokens" })
    XCTAssertEqual(session.label, "5-hour token limit")
    XCTAssertEqual(session.remainingPercent, 60)

    // JSON null is no unit at all, so that entry is still the legacy shape.
    let nullUnit = #"{"type": "TOKENS_LIMIT", "unit": null, "percentage": 40}"#
    let legacy = try await fetch(payload(tokenLimits: [nullUnit], planReset: nil))
    XCTAssertEqual(legacy.metrics.map(\.id), ["tokens", "mcp"])
    XCTAssertEqual(legacy.metrics.first?.label, "Token limit")
  }

  // An unreadable percentage fails the refresh wherever the entry sits, as
  // it always has for the token entry. Skipping it would silently drop a
  // window, possibly the binding weekly cap; failing lets the coordinator
  // record the error and keep the account's last good usage.
  func testMalformedTokenEntryFailsTheRefreshInEitherPosition() async {
    let malformed = #"{"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": "n/a"}"#

    for tokenLimits in [[malformed, Self.fiveHourEntry], [Self.fiveHourEntry, malformed]] {
      do {
        _ = try await fetch(payload(tokenLimits: tokenLimits, planReset: nil))
        XCTFail("A malformed token entry must fail the refresh")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .decoding)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  // The shape this client was written for: one TOKENS_LIMIT entry without
  // `unit`. It keeps today's id, per-host label, and warning.
  func testLegacySingleTokenEntryIsUnchanged() async throws {
    let zai = try await fetch(payload(planReset: nil))
    XCTAssertEqual(zai.metrics.map(\.id), ["tokens", "mcp"])
    XCTAssertEqual(zai.metrics.map(\.label), ["Token limit", "MCP monthly quota"])
    XCTAssertEqual(zai.maxUsagePercent, 40)
    XCTAssertNil(zai.warning)
    XCTAssertEqual(defaultRingMetrics(for: zai).map(\.id), ["tokens", "mcp"])

    let zhipu = try await fetch(payload(planReset: nil), provider: .zhipu)
    XCTAssertEqual(zhipu.metrics.map(\.label), ["5-hour token limit", "MCP monthly quota"])
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

  /// The single token entry without `unit` that this client was written for.
  private static let legacyTokenEntry =
    #"{"type": "TOKENS_LIMIT", "percentage": 40, "currentValue": 4000000, "usage": 10000000}"#

  /// The GLM Coding Plan's per-window entries, with millisecond resets as
  /// third-party monitors observe them: (3, 5) is the 5-hour window and
  /// (6, 1) the weekly one.
  private static let fiveHourEntry = """
    {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 40, \
    "currentValue": 4000000, "usage": 10000000, "nextResetTime": 1700010000000}
    """
  private static let weeklyEntry =
    #"{"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 85, "nextResetTime": 1700300000000}"#

  /// `currentValue` is the used count and `usage` the entitlement, matching the
  /// key precedence the client reads.
  private func payload(
    tokenLimits: [String] = [ZhipuQuotaClientTests.legacyTokenEntry],
    timeLimitReset: String? = nil,
    planReset: String?
  ) -> String {
    let entryReset = timeLimitReset.map { ", \"resetTime\": \"\($0)\"" } ?? ""
    let dataReset = planReset.map { ", \"nextResetTime\": \"\($0)\"" } ?? ""
    let tokens = tokenLimits.joined(separator: ",\n")
    return """
    {
      "success": true,
      "code": 200,
      "data": {
        "limits": [
          \(tokens),
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
