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
