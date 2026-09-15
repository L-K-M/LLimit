import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MetaMuseClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_300_000)

  private func config(key: String? = "meta-api-key") -> ProviderRuntimeConfiguration {
    var credentials: [String: String] = [:]
    if let key { credentials[CredentialField.metaMuseAPIKey] = key }
    return ProviderRuntimeConfiguration(
      provider: .metaMuse,
      isEnabled: true,
      credentials: credentials
    )
  }

  private func sse(_ event: String, _ json: String) -> String {
    "event: \(event)\ndata: \(json)\n\n"
  }

  // The shape Muse Code's runtime decodes off the stream: window carries its
  // length in minutes plus a reset, weekly carries just percent + reset.
  func testParsesSubscriptionUsageEvent() async throws {
    let body = sse("response.created", #"{"type":"response.created","response":{"id":"r1"}}"#)
      + sse("response.subscription_usage", #"{"type":"response.subscription_usage","window":{"used_percent":40,"window_duration_mins":300,"resets_at":"2026-09-15T02:00:00Z"},"weekly":{"used_percent":60,"resets_at":"2026-09-21T00:00:00Z"}}"#)
      + sse("response.completed", #"{"type":"response.completed","response":{"id":"r1","status":"completed"}}"#)
      + "data: [DONE]\n\n"
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.provider, .metaMuse)
    XCTAssertEqual(usage.metrics.map(\.id), ["window", "weekly"])

    let window = try XCTUnwrap(usage.metrics.first { $0.id == "window" })
    XCTAssertEqual(window.label, "5-hour limit")
    XCTAssertEqual(window.remainingPercent, 60)
    XCTAssertEqual(window.resetAt, parseISO8601("2026-09-15T02:00:00Z"))
    XCTAssertEqual(QuotaWindowKind.classify(metricID: window.id, label: window.label), .session)

    let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "weekly" })
    XCTAssertEqual(weekly.remainingPercent, 40)
    XCTAssertEqual(weekly.resetAt, parseISO8601("2026-09-21T00:00:00Z"))
    XCTAssertEqual(QuotaWindowKind.classify(metricID: weekly.id, label: weekly.label), .weekly)

    XCTAssertEqual(usage.maxUsagePercent, 60)
    XCTAssertNil(usage.warning)
  }

  // The event may nest the snapshot under a `subscription_usage` key instead
  // of inlining its fields.
  func testParsesNestedSubscriptionUsageKey() async throws {
    let body = sse("response.subscription_usage", #"{"type":"response.subscription_usage","subscription_usage":{"weekly":{"used_percent":"25","resets_at":"2026-09-21T00:00:00Z"}}}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.map(\.id), ["weekly"])
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 75)
  }

  // Non-streamed or CLI-shaped responses carry the same snapshot inside the
  // completed response object.
  func testParsesSnapshotFromCompletedResponseObject() async throws {
    let body = sse("response.completed", #"{"type":"response.completed","response":{"id":"r2","subscription_usage":{"window":{"used_percent":10,"window_duration_mins":90,"resets_at":"2026-09-15T01:00:00Z"}}}}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    let window = try XCTUnwrap(usage.metrics.first { $0.id == "window" })
    XCTAssertEqual(window.label, "90-minute limit")
    XCTAssertEqual(window.remainingPercent, 90)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: window.id, label: window.label), .session)
  }

  func testParsesPlainJSONBody() async throws {
    let body = #"{"id":"r3","subscription_usage":{"weekly":{"used_percent":80}}}"#
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.first { $0.id == "weekly" }?.remainingPercent, 20)
    XCTAssertEqual(usage.maxUsagePercent, 80)
    XCTAssertEqual(usage.warning, "High usage")
  }

  // Pay-as-you-go keys get no subscription frame.
  func testNoSubscriptionEventYieldsPlaceholderMetric() async throws {
    let body = sse("response.completed", #"{"type":"response.completed","response":{"id":"r4","status":"completed"}}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.map(\.id), ["empty"])
    XCTAssertEqual(usage.metrics.first?.label, "Pay-as-you-go — no subscription quota")
    XCTAssertEqual(usage.maxUsagePercent, 0)
  }

  // SSE permits CRLF; without normalization a multi-event body never splits.
  func testParsesCRLFDelimitedStream() async throws {
    let body = "event: response.subscription_usage\r\ndata: {\"type\":\"response.subscription_usage\",\"weekly\":{\"used_percent\":50}}\r\n\r\nevent: response.completed\r\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r5\"}}\r\n\r\n"
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.first { $0.id == "weekly" }?.remainingPercent, 50)
  }

  // A window without window_duration_mins falls back to a session label.
  func testWindowWithoutDurationUsesSessionLabel() async throws {
    let body = sse("response.subscription_usage", #"{"type":"response.subscription_usage","window":{"used_percent":10}}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    let window = try XCTUnwrap(usage.metrics.first { $0.id == "window" })
    XCTAssertEqual(window.label, "Session window")
    XCTAssertEqual(QuotaWindowKind.classify(metricID: window.id, label: window.label), .session)
  }

  // Over-100% used must never surface as a negative remaining percent.
  func testOveragePercentClampsToZeroRemaining() async throws {
    let body = sse("response.subscription_usage", #"{"type":"response.subscription_usage","weekly":{"used_percent":150}}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))

    let usage = try await client.fetchUsage(configuration: config(), now: now)

    XCTAssertEqual(usage.metrics.first { $0.id == "weekly" }?.remainingPercent, 0)
    XCTAssertEqual(usage.warning, "Quota exhausted")
  }

  // A 200 that parses into nothing recognizable is a protocol break, not a
  // healthy pay-as-you-go answer — it must fail loudly.
  func testUnrecognizableBodyThrowsAPI() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: "<html>not a stream</html>"))
    await assertThrows(kind: .api, messageContains: "no recognizable usage payload") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  // Stream-level errors arrive as HTTP 200 events — not pay-as-you-go, and
  // the thrown error headlines the API's own message.
  func testStreamErrorEventThrowsAPI() async {
    let body = sse("error", #"{"type":"error","code":"invalid_api_key","message":"bad key"}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))
    await assertThrows(kind: .api, messageContains: "bad key") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  // A healthy event before the error must not read as pay-as-you-go either.
  func testStreamErrorAfterHealthyEventThrowsAPI() async {
    let body = sse("response.created", #"{"type":"response.created","response":{"id":"r6"}}"#)
      + sse("error", #"{"type":"error","code":"invalid_api_key","message":"bad key"}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))
    await assertThrows(kind: .api, messageContains: "bad key") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  // response.failed nests its error under response.error.
  func testStreamFailedEventThrowsAPI() async {
    let body = sse("response.failed", #"{"type":"response.failed","response":{"id":"r7","error":{"code":"server_error","message":"upstream unavailable"}}}"#)
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: body))
    await assertThrows(kind: .api, messageContains: "upstream unavailable") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  // Same for a 200 whose whole body is an error envelope.
  func testJSONErrorBodyThrowsAPI() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: #"{"error":{"message":"bad key"}}"#))
    await assertThrows(kind: .api, messageContains: "bad key") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testServerErrorThrowsAPI() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 503, body: "upstream unavailable"))
    await assertThrows(kind: .api, messageContains: "unavailable") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testSendsMinimalStreamingProbe() async throws {
    let mock = MuseCapturingHTTP(status: 200, body: "data: [DONE]\n\n")
    let client = MetaMuseQuotaClient(httpClient: mock)

    _ = try await client.fetchUsage(configuration: config(), now: now)

    let request = try XCTUnwrap(mock.lastRequest)
    XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/v1/responses")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer meta-api-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-version"), "1.0.0")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["stream"] as? Bool, true)
    XCTAssertNotNil(json["model"])
    XCTAssertEqual(json["store"] as? Bool, false)
    XCTAssertEqual(json["max_output_tokens"] as? Int, 16, "quota probe must cap paid generation")
    XCTAssertEqual(json["input"] as? String, "ping")
  }

  func testMissingKeyThrowsNotConfigured() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 200, body: ""))
    await assertThrows(kind: .notConfigured) {
      try await client.fetchUsage(configuration: self.config(key: nil), now: self.now)
    }
  }

  func testUnauthorizedThrowsAuth() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 401, body: #"{"error":{"type":"authentication_error","message":"Unauthorized"}}"#))
    await assertThrows(kind: .auth) {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  func testRateLimitThrowsRateLimit() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 429, body: #"{"error":{"type":"rate_limit","message":"slow down"}}"#))
    await assertThrows(kind: .rateLimit, messageContains: "slow down") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  // The muse-code service answers problem+json rather than the OpenAI envelope.
  func testProblemJSONErrorThrowsAPI() async {
    let client = MetaMuseQuotaClient(httpClient: MuseMockHTTP(status: 400, body: #"{"title":"Bad Request","detail":"model not found","status":400}"#))
    await assertThrows(kind: .api, messageContains: "model not found") {
      try await client.fetchUsage(configuration: self.config(), now: self.now)
    }
  }

  private func assertThrows(
    kind: QuotaErrorKind,
    messageContains: String? = nil,
    _ block: @escaping () async throws -> ProviderUsage,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await block()
      XCTFail("Expected error of kind \(kind)", file: file, line: line)
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind, file: file, line: line)
      if let messageContains {
        XCTAssertTrue(
          error.message.contains(messageContains),
          "Expected message containing \"\(messageContains)\", got: \(error.message)",
          file: file,
          line: line
        )
      }
    } catch {
      XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
  }
}

private struct MuseMockHTTP: HTTPClient {
  let status: Int
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (body.data(using: .utf8)!, response)
  }
}

private final class MuseCapturingHTTP: HTTPClient, @unchecked Sendable {
  let status: Int
  let body: String
  private let lock = NSLock()
  private var _lastRequest: URLRequest?
  var lastRequest: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return _lastRequest
  }

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.lock()
    _lastRequest = request
    lock.unlock()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (body.data(using: .utf8)!, response)
  }
}
