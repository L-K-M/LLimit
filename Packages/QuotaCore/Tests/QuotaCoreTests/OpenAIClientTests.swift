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

  // 429 is a rate limit, not a generic API error: consumers suppress warnings
  // and keep stale data for .rateLimit but fail loudly for .api.
  func testRateLimitedResponseMapsToRateLimitKind() async {
    let client = OpenAIClient(httpClient: RecordingOpenAIHTTP(status: 429, body: #"{"detail":"Too many requests"}"#))
    do {
      _ = try await client.fetchUsage(configuration: config(credentials: [
        CredentialField.openAIAccessToken: "manual-access"
      ]), now: now)
      XCTFail("Expected a rate-limit failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // Odd window durations must label their exact unit: a rounded "1-hour
  // limit" for a 45-minute window also misclassifies the identity color.
  func testWindowLabelsUseExactUnits() async throws {
    for (seconds, expectedLabel) in [
      (2_700, "45-minute limit"),
      (5_400, "90-minute limit"),
      (90_000, "25-hour limit"),
      (18_000, "5-hour limit"),
      (604_800, "7-day limit"),
      (30, "30-second limit")
    ] {
      let body = #"{"plan_type":"plus","rate_limit":{"limit_reached":false,"primary_window":{"used_percent":20,"limit_window_seconds":\#(seconds),"reset_after_seconds":3600}}}"#
      let http = RecordingOpenAIHTTP(status: 200, body: body)
      let client = OpenAIClient(httpClient: http)
      let usage = try await client.fetchUsage(configuration: config(credentials: [
        CredentialField.openAIAccessToken: "manual-access"
      ]), now: now)

      let label = try XCTUnwrap(usage.metrics.first?.label, "for \(seconds) seconds")
      XCTAssertEqual(label, expectedLabel, "for \(seconds) seconds")
      // The label is the classifier's input: pin the label-to-kind contract
      // so a future wording change cannot silently rekey identity colors.
      let metricID = try XCTUnwrap(usage.metrics.first?.id)
      switch seconds {
      case 604_800:
        XCTAssertEqual(QuotaWindowKind.classify(metricID: metricID, label: label), .weekly)
      case 90_000:
        XCTAssertEqual(QuotaWindowKind.classify(metricID: metricID, label: label), .daily)
      default:
        XCTAssertEqual(QuotaWindowKind.classify(metricID: metricID, label: label), .session)
      }
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
