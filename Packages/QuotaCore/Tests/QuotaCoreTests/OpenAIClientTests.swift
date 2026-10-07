import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenAIClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testManagedAccountUsesItsSourceWithoutHTTPOrCopiedTokens() async throws {
    let http = RecordingOpenAIHTTP()
    let source = RecordingManagedSource()
    let client = OpenAIClient(httpClient: http, managedSource: source)
    let credentials = CodexAccountProfile().credentials(identity: CodexAccountIdentity(accountID: "workspace", userID: "member"))
    let configuration = config(credentials: credentials)
    let usage = try await client.fetchUsage(configuration: configuration, now: now)

    XCTAssertEqual(usage.accountID, configuration.accountID)
    XCTAssertEqual(usage.metrics[0].remainingPercent, 72)
    let calls = await source.configurations
    let requests = await http.requests
    XCTAssertEqual(calls, [configuration])
    XCTAssertTrue(requests.isEmpty)
  }

  func testManagedFailureNeverFallsBackToHTTPWithStaleCopiedTokens() async {
    let http = RecordingOpenAIHTTP()
    let source = RecordingManagedSource(error: ProviderClientError(kind: .auth, message: "Reconnect OpenAI"))
    let client = OpenAIClient(httpClient: http, managedSource: source)
    do {
      _ = try await client.fetchUsage(configuration: config(credentials: [
        CredentialField.openAICodexProfileID: UUID().uuidString,
        CredentialField.openAIAccessToken: "stale-copy"
      ]), now: now)
      XCTFail("Expected managed source failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
    } catch { XCTFail("Unexpected error: \(error)") }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testMissingManagedSourceFailsClosedEvenWithMalformedMarkerAndToken() async {
    for marker in [UUID().uuidString, "", "malformed"] {
      let http = RecordingOpenAIHTTP()
      let client = OpenAIClient(httpClient: http)
      do {
        _ = try await client.fetchUsage(configuration: config(credentials: [
          CredentialField.openAICodexProfileID: marker, CredentialField.openAIAccessToken: "stale-copy"
        ]), now: now)
        XCTFail("Expected missing managed source error")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .notConfigured)
      } catch { XCTFail("Unexpected error: \(error)") }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testManualAccountUsesHTTPAndDoesNotStartManagedSource() async throws {
    let http = RecordingOpenAIHTTP()
    let source = RecordingManagedSource()
    let client = OpenAIClient(httpClient: http, managedSource: source)
    let usage = try await client.fetchUsage(configuration: config(credentials: [
      CredentialField.openAIAccessToken: "manual-access", CredentialField.openAIAccountID: "workspace"
    ]), now: now)
    XCTAssertEqual(usage.metrics[0].remainingPercent, 80)
    let calls = await source.configurations
    let requests = await http.requests
    XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer manual-access")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "workspace")
  }

  func testReportedWindowLengthRemainsAvailableForPace() async throws {
    let usage = try await OpenAIClient(httpClient: RecordingOpenAIHTTP()).fetchUsage(configuration: config(credentials: [
      CredentialField.openAIAccessToken: "manual-access"
    ]), now: now)
    XCTAssertEqual(usage.metrics.map(\.windowSeconds), [18_000])
  }

  func testRateLimitAndExactWindowLabels() async throws {
    do {
      _ = try await OpenAIClient(httpClient: RecordingOpenAIHTTP(status: 429, body: "secret response")).fetchUsage(configuration: config(credentials: [CredentialField.openAIAccessToken: "manual-access"]), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
      XCTAssertFalse(error.message.contains("secret response"))
    }
    for (seconds, label, kind) in [(2_700, "45-minute limit", QuotaWindowKind.session), (5_400, "90-minute limit", .session),
                                    (90_000, "25-hour limit", .daily), (18_000, "5-hour limit", .session),
                                    (604_800, "7-day limit", .weekly), (30, "30-second limit", .session)] {
      let body = #"{"plan_type":"plus","rate_limit":{"limit_reached":false,"primary_window":{"used_percent":20,"limit_window_seconds":\#(seconds),"reset_after_seconds":3600}}}"#
      let usage = try await OpenAIClient(httpClient: RecordingOpenAIHTTP(body: body)).fetchUsage(configuration: config(credentials: [CredentialField.openAIAccessToken: "manual-access"]), now: now)
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertEqual(metric.label, label)
      XCTAssertEqual(metric.windowSeconds, seconds)
      XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), kind)
    }
  }

  private func config(credentials: [String: String]) -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: "llimit-account", provider: .openAI, displayName: "OpenAI Work", isEnabled: true, credentials: credentials)
  }
}

private actor RecordingManagedSource: ManagedOpenAIUsageSource {
  private(set) var configurations: [ProviderRuntimeConfiguration] = []
  private let error: ProviderClientError?

  init(error: ProviderClientError? = nil) { self.error = error }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    configurations.append(configuration)
    if let error { throw error }
    return ProviderUsage(accountID: configuration.accountID, provider: .openAI, title: configuration.displayName,
      metrics: [UsageMetric(id: "primary", label: "5-hour limit", remainingPercent: 72)], fetchedAt: now)
  }
}

private actor RecordingOpenAIHTTP: HTTPClient {
  private(set) var requests: [URLRequest] = []
  private let status: Int
  private let body: String

  init(status: Int = 200, body: String = #"{"plan_type":"plus","rate_limit":{"limit_reached":false,"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600}}}"#) {
    self.status = status
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
