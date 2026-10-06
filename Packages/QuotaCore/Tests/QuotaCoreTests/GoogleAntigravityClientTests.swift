import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class GoogleAntigravityClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func configuration() -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      provider: .googleAntigravity,
      isEnabled: true,
      credentials: [
        CredentialField.googleRefreshToken: "refresh-token",
        CredentialField.googleProjectID: "project-1",
        CredentialField.googleEmail: "user@example.com"
      ]
    )
  }

  // Regression test: a model whose quotaInfo is missing (or no longer
  // parsable after schema drift) must read as unknown, never as 0% remaining.
  // The old `?? 0` fabrication showed the account as fully exhausted and
  // raised the high-usage warning.
  func testMissingRemainingFractionReportsUnknownNotZero() async throws {
    let models = """
    {
      "models": {
        "gemini-3-pro-high": {"quotaInfo": {"remainingFraction": 0.64, "resetTime": "2023-11-15T10:00:00Z"}},
        "gemini-3-flash": {"quotaInfo": {}},
        "claude-opus-4-5-thinking": {}
      }
    }
    """
    let client = GoogleAntigravityClient(httpClient: MockAntigravityHTTP(modelsBody: models))

    let usage = try await client.fetchUsage(configuration: configuration(), now: now)

    let pro = try XCTUnwrap(usage.metrics.first { $0.id == "gemini-3-pro-high" })
    XCTAssertEqual(pro.remainingPercent, 64)

    let flash = try XCTUnwrap(usage.metrics.first { $0.id == "gemini-3-flash" })
    XCTAssertNil(flash.remainingPercent, "a missing fraction is unknown, not zero")

    let claude = try XCTUnwrap(usage.metrics.first { $0.id == "claude-opus-4-5-thinking" })
    XCTAssertNil(claude.remainingPercent)

    // maxUsage comes only from models with real data; the unknowns must not
    // drive it to 100.
    XCTAssertEqual(usage.maxUsagePercent, 36)
    XCTAssertNil(usage.warning)
  }

  func testHappyPathParsesFractionsAndResets() async throws {
    let models = """
    {
      "models": {
        "gemini-3-pro-high": {"quotaInfo": {"remainingFraction": 0.1, "resetTime": "2023-11-15T10:00:00Z"}}
      }
    }
    """
    let client = GoogleAntigravityClient(httpClient: MockAntigravityHTTP(modelsBody: models))

    let usage = try await client.fetchUsage(configuration: configuration(), now: now)

    let pro = try XCTUnwrap(usage.metrics.first { $0.id == "gemini-3-pro-high" })
    XCTAssertEqual(pro.remainingPercent, 10)
    XCTAssertEqual(pro.resetAt, Date(timeIntervalSince1970: 1_700_042_400))
    XCTAssertEqual(usage.maxUsagePercent, 90)
    XCTAssertEqual(usage.warning, "High usage")
    XCTAssertEqual(usage.subtitle, "user@example.com")
  }
}

/// Serves the two-call sequence the client makes: the OAuth token refresh,
/// then the models fetch.
private struct MockAntigravityHTTP: HTTPClient {
  private let modelsBody: String

  init(modelsBody: String) {
    self.modelsBody = modelsBody
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body: String
    if request.url?.host == "oauth2.googleapis.com" {
      XCTAssertEqual(request.httpMethod, "POST")
      body = #"{"access_token":"mock-access-token","expires_in":3600}"#
    } else {
      XCTAssertEqual(request.url?.host, "cloudcode-pa.googleapis.com")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-access-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "antigravity/1.11.9 windows/amd64")
      body = modelsBody
    }

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (Data(body.utf8), response)
  }
}
