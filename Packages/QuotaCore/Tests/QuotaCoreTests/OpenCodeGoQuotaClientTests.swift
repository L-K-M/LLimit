import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenCodeGoQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_510_400)
  private let secret = "fixture-go-key"
  private let validBody = #"""
  {"usage": {
    "rolling": {"status": "ok", "percent": 25, "resetsAt": "2026-09-27T19:34:56.123Z"},
    "weekly": {"status": "ok", "percent": 60, "resetsAt": "2026-09-28T00:00:00.000Z"},
    "monthly": {"status": "ok", "percent": 10, "resetsAt": "2026-10-09T08:15:00.000Z"}
  }}
  """#

  private func configuration(key: String? = "fixture-go-key") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "go-personal",
      provider: .openCodeGo,
      displayName: "Personal Go",
      isEnabled: true,
      credentials: key.map { [CredentialField.openCodeGoAPIKey: $0] } ?? [:]
    )
  }

  func testFetchesAllWindowsWithoutInferringResetCadence() async throws {
    let http = RecordingGoHTTP(status: 200, body: validBody)
    let client = OpenCodeGoQuotaClient(httpClient: http)
    let usage = try await client.fetchUsage(configuration: configuration(key: " \(secret)\n"), now: now)

    XCTAssertEqual(usage.provider, .openCodeGo)
    XCTAssertEqual(usage.accountID, "go-personal")
    XCTAssertEqual(usage.title, "Personal Go")
    XCTAssertEqual(usage.subtitle, "OpenCode Go")
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(usage.metrics.map(\.id), ["session-rolling", "weekly", "monthly"])
    XCTAssertEqual(usage.metrics.map(\.label), ["Rolling limit", "Weekly limit", "Monthly limit"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [75, 40, 90])
    XCTAssertEqual(usage.metrics.map(\.usedDisplay), ["25%", "60%", "10%"])
    XCTAssertEqual(usage.maxUsagePercent, 60)
    XCTAssertNil(usage.warning)
    XCTAssertEqual(usage.metrics[0].resetAt, parseISO8601("2026-09-27T19:34:56.123Z"))
    XCTAssertEqual(usage.metrics[2].resetAt, parseISO8601("2026-10-09T08:15:00.000Z"))
    XCTAssertEqual(usage.metrics[0].resetIn, formatResetCountdown(to: try XCTUnwrap(usage.metrics[0].resetAt), now: now))
    XCTAssertEqual(usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }, [.session, .weekly, .monthly])

    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/usage")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertFalse(request.httpShouldHandleCookies)
  }

  func testExhaustedWindowIsValidUsageAndWarns() async throws {
    let body = validBody.replacingOccurrences(of: #""status": "ok", "percent": 60"#, with: #""status": "rate-limited", "percent": 100"#)
    let usage = try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: 200, body: body))
      .fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics[1].remainingPercent, 0)
    XCTAssertEqual(usage.metrics[1].detail, "Limit reached")
    XCTAssertEqual(usage.maxUsagePercent, 100)
    XCTAssertEqual(usage.warning, "Limit reached")
  }

  func testUnusedWindowsRemainFull() async throws {
    let body = validBody
      .replacingOccurrences(of: "\"percent\": 25", with: "\"percent\": 0")
      .replacingOccurrences(of: "\"percent\": 60", with: "\"percent\": 0")
      .replacingOccurrences(of: "\"percent\": 10", with: "\"percent\": 0")
    let usage = try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: 200, body: body))
      .fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [100, 100, 100])
    XCTAssertEqual(usage.maxUsagePercent, 0)
    XCTAssertNil(usage.warning)
  }

  func testHighUsageWarningBeforeLimit() async throws {
    let body = validBody.replacingOccurrences(of: "\"percent\": 60", with: "\"percent\": 80")
    let usage = try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: 200, body: body))
      .fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.warning, "High usage")
  }

  func testRejectsMissingAndInvalidKeysWithoutRequest() async {
    for key in [nil, "", " \n", "fixture\nkey", "fixture key", "fixture\u{0000}key"] as [String?] {
      let http = RecordingGoHTTP(status: 200, body: validBody)
      await assertFailure(.notConfigured) {
        try await OpenCodeGoQuotaClient(httpClient: http).fetchUsage(configuration: self.configuration(key: key), now: self.now)
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testRejectsIncompleteOrUnexpectedPayloads() async {
    for body in ["{}", "[]", "<html>Sign in</html>", #"{"usage":{}}"#,
                 #"{"error":{"message":"fixture-go-key"}}"#,
                 validBody.replacingOccurrences(of: "\"monthly\":", with: "\"unrecognizedWindow\":")] {
      await assertFailure(.decoding) {
        try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: 200, body: body))
          .fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testRejectsInvalidPercentages() async {
    for value in ["-1", "101", "25.5", "true", "null", "\"25\"", "1e1000"] {
      let body = validBody.replacingOccurrences(of: "\"percent\": 25", with: "\"percent\": \(value)")
      await assertFailure(.decoding) {
        try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: 200, body: body))
          .fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testRejectsInvalidStatusAndResetTimestamp() async {
    let invalidBodies = [
      validBody.replacingOccurrences(of: "\"status\": \"ok\"", with: "\"status\": \"unknown\""),
      validBody.replacingOccurrences(of: "\"status\": \"ok\"", with: "\"status\": \"rate-limited\""),
      validBody.replacingOccurrences(of: "2026-09-27T19:34:56.123Z", with: "invalid fixture-go-key"),
      validBody.replacingOccurrences(of: "2026-09-27T19:34:56.123Z", with: "2026-09-27")
    ]
    for body in invalidBodies {
      await assertFailure(.decoding) {
        try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: 200, body: body))
          .fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testMapsStatusCodesWithoutExposingResponseBody() async {
    for (status, kind) in [(401, QuotaErrorKind.auth), (403, .auth), (429, .rateLimit), (500, .api), (302, .api)] {
      await assertFailure(kind) {
        try await OpenCodeGoQuotaClient(httpClient: RecordingGoHTTP(status: status, body: #"{"error":"fixture-go-key"}"#))
          .fetchUsage(configuration: self.configuration(), now: self.now)
      }
    }
  }

  func testSanitizesTransportErrors() async {
    await assertFailure(.network) {
      try await OpenCodeGoQuotaClient(httpClient: FailingGoHTTP())
        .fetchUsage(configuration: self.configuration(), now: self.now)
    }
  }

  private func assertFailure(
    _ kind: QuotaErrorKind,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> ProviderUsage
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(kind) error", file: file, line: line)
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind, file: file, line: line)
      XCTAssertFalse(error.message.contains(secret), file: file, line: line)
    } catch {
      XCTFail("Expected a sanitized provider error", file: file, line: line)
    }
  }
}

private actor RecordingGoHTTP: HTTPClient {
  let status: Int
  let body: String
  private(set) var requests: [URLRequest] = []

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

private struct FailingGoHTTP: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw ProviderClientError(kind: .network, message: "fixture-go-key")
  }
}
