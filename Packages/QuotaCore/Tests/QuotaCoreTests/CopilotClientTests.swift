import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CopilotClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func oauthConfig() -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      provider: .gitHubCopilot,
      isEnabled: true,
      credentials: [CredentialField.copilotOAuthToken: "gho_test"]
    )
  }

  private func patConfig() -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      provider: .gitHubCopilot,
      isEnabled: true,
      credentials: [
        CredentialField.copilotPATToken: "ghp_test",
        CredentialField.copilotUsername: "octocat",
        CredentialField.copilotTier: "pro"
      ]
    )
  }

  // Regression test: the real copilot_internal/user response reports fractional
  // premium-request quotas (e.g. 1327.56). Decoding these as Int used to throw and
  // fail the whole fetch for every active account.
  func testInternalUsageDecodesFractionalQuota() async throws {
    let json = #"""
    {
      "copilot_plan": "pro",
      "quota_reset_date": "2026-08-01",
      "quota_snapshots": {
        "premium_interactions": {
          "entitlement": 300,
          "overage_count": 0,
          "overage_permitted": false,
          "percent_remaining": 88.50399999999999,
          "quota_id": "premium_interactions",
          "quota_remaining": 265.51,
          "remaining": 265.51,
          "unlimited": false
        },
        "chat": {"entitlement": 0, "overage_count": 0, "overage_permitted": true, "percent_remaining": 100, "quota_id": "chat", "quota_remaining": 0, "remaining": 0, "unlimited": true},
        "completions": {"entitlement": 0, "overage_count": 0, "overage_permitted": true, "percent_remaining": 100, "quota_id": "completions", "quota_remaining": 0, "remaining": 0, "unlimited": true}
      }
    }
    """#

    let client = CopilotClient(httpClient: MockHTTP(status: 200, body: json))
    let usage = try await client.fetchUsage(configuration: oauthConfig(), now: now)

    let premium = usage.metrics.first { $0.id == "premium" }
    XCTAssertNotNil(premium)
    XCTAssertEqual(premium?.remainingPercent, 89) // 88.504 rounded
    XCTAssertEqual(premium?.usedDisplay, "34")     // 300 - 265.51 = 34.49 -> 34
    XCTAssertEqual(premium?.totalDisplay, "300")
  }

  // Regression test: the billing API types grossQuantity/netQuantity as numbers.
  func testBillingPathDecodesFractionalQuantities() async throws {
    let json = #"""
    {
      "timePeriod": {"year": 2026, "month": 7},
      "user": "octocat",
      "usageItems": [
        {"product": "copilot", "sku": "Copilot Premium Request", "model": "gpt-5", "unitType": "premium_request", "grossQuantity": 33.75, "netQuantity": 33.75}
      ]
    }
    """#

    let client = CopilotClient(httpClient: MockHTTP(status: 200, body: json))
    let usage = try await client.fetchUsage(configuration: patConfig(), now: now)

    let premium = usage.metrics.first { $0.id == "premium" }
    XCTAssertEqual(premium?.usedDisplay, "34")   // 33.75 -> 34
    XCTAssertEqual(premium?.totalDisplay, "300") // pro tier limit
    XCTAssertEqual(premium?.remainingPercent, 89) // (300-33.75)/300 -> 88.75 -> 89
  }

  // Regression test: a GitHub server error used to fall through the whole
  // auth-mode fallback chain and surface as `.auth` ("Configure a PAT…"),
  // telling the user their token was broken during an outage. The OAuth path
  // hits `copilot_internal/user` first, so the 503 pins the quota-API hunk.
  func testInternalServerErrorFailsAsAPIError() async {
    let client = CopilotClient(httpClient: MockHTTP(status: 503, body: "upstream unavailable"))
    do {
      _ = try await client.fetchUsage(configuration: oauthConfig(), now: now)
      XCTFail("Expected an API failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .api)
      XCTAssertTrue(error.message.hasPrefix("Copilot quota API error 503"), "got: \(error.message)")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // Covers the other 5xx hunk: both auth modes rejected (401 -> try next),
  // then the session-token exchange fails with a server error. It must fail
  // as `.api` with the response body instead of continuing the chain into a
  // misleading `.auth`.
  func testTokenExchangeServerErrorFailsAsAPIError() async {
    let client = CopilotClient(httpClient: SequencedMockHTTP(responses: [
      (401, #"{"message":"Bad credentials"}"#),
      (401, #"{"message":"Bad credentials"}"#),
      (503, "proxy unavailable")
    ]))
    do {
      _ = try await client.fetchUsage(configuration: oauthConfig(), now: now)
      XCTFail("Expected an API failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .api)
      XCTAssertTrue(
        error.message.hasPrefix("Copilot token exchange error 503") && error.message.contains("proxy unavailable"),
        "got: \(error.message)"
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testBillingRateLimitMapsToRateLimit() async {
    let client = CopilotClient(httpClient: MockHTTP(status: 429, body: "rate limited"))
    do {
      _ = try await client.fetchUsage(configuration: patConfig(), now: now)
      XCTFail("Expected a rate-limit failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private struct MockHTTP: HTTPClient {
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

/// Serves the given (status, body) responses in request order, so a test can
/// drive a specific position in Copilot's sequential fallback chain.
private actor SequencedMockHTTP: HTTPClient {
  private var responses: [(status: Int, body: String)]

  init(responses: [(status: Int, body: String)]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = responses.isEmpty ? (status: 404, body: "") : responses.removeFirst()
    let httpResponse = HTTPURLResponse(
      url: request.url!,
      statusCode: response.status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (response.body.data(using: .utf8)!, httpResponse)
  }
}
