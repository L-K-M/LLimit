import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class GoogleAntigravityClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func configuration(
    refreshToken: String = "fake-refresh-token",
    projectID: String = "test-project-123",
    email: String = "user@example.com"
  ) -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "google-test",
      provider: .googleAntigravity,
      displayName: "Google Test",
      isEnabled: true,
      credentials: [
        CredentialField.googleRefreshToken: refreshToken,
        CredentialField.googleProjectID: projectID,
        CredentialField.googleEmail: email
      ]
    )
  }

  func testHappyPathFetchesModelsAndCalculatesQuota() async throws {
    let tokenJSON = #"{"access_token": "token-abc", "expires_in": 3600}"#
    let modelsJSON = #"""
    {
      "models": {
        "gemini-3-pro-high": {
          "quotaInfo": {
            "remainingFraction": 0.85,
            "resetTime": "2023-11-15T00:00:00Z"
          }
        },
        "gemini-3-flash": {
          "quotaInfo": {
            "remainingFraction": 0.50,
            "resetTime": "2023-11-15T00:00:00Z"
          }
        }
      }
    }
    """#

    let http = MockGoogleHTTP(tokenResponse: tokenJSON, modelsResponse: modelsJSON)
    let client = GoogleAntigravityClient(httpClient: http)
    let usage = try await client.fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.provider, .googleAntigravity)
    XCTAssertEqual(usage.title, "Google Test")
    XCTAssertEqual(usage.subtitle, "user@example.com")
    XCTAssertEqual(usage.metrics.count, 2)
    let metricsByID = Dictionary(uniqueKeysWithValues: usage.metrics.map { ($0.id, $0) })
    XCTAssertEqual(metricsByID["gemini-3-pro-high"]?.remainingPercent, 85)
    XCTAssertEqual(metricsByID["gemini-3-flash"]?.remainingPercent, 50)
    XCTAssertEqual(usage.maxUsagePercent, 50)
    XCTAssertNil(usage.warning)
  }

  func testMissingFractionYieldsNilRemainingPercentWithoutFalseHighUsageWarning() async throws {
    let tokenJSON = #"{"access_token": "token-abc", "expires_in": 3600}"#
    let modelsJSON = #"""
    {
      "models": {
        "gemini-3-pro-high": {
          "quotaInfo": {
            "resetTime": "2023-11-15T00:00:00Z"
          }
        }
      }
    }
    """#

    let http = MockGoogleHTTP(tokenResponse: tokenJSON, modelsResponse: modelsJSON)
    let client = GoogleAntigravityClient(httpClient: http)
    let usage = try await client.fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.count, 1)
    XCTAssertEqual(usage.metrics[0].id, "gemini-3-pro-high")
    XCTAssertNil(usage.metrics[0].remainingPercent, "Missing remainingFraction must NOT default to 0")
    XCTAssertEqual(usage.maxUsagePercent, 0)
    XCTAssertNil(usage.warning, "Missing fraction must not trigger a high usage warning")
  }

  func testUnparseableFractionYieldsNilRemainingPercent() async throws {
    let tokenJSON = #"{"access_token": "token-abc", "expires_in": 3600}"#
    let modelsJSON = #"""
    {
      "models": {
        "gemini-3-pro-high": {
          "quotaInfo": {
            "remainingFraction": "n/a",
            "resetTime": "2023-11-15T00:00:00Z"
          }
        }
      }
    }
    """#

    let http = MockGoogleHTTP(tokenResponse: tokenJSON, modelsResponse: modelsJSON)
    let client = GoogleAntigravityClient(httpClient: http)
    let usage = try await client.fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.count, 1)
    XCTAssertEqual(usage.metrics[0].id, "gemini-3-pro-high")
    XCTAssertNil(usage.metrics[0].remainingPercent, "Non-numeric fraction must NOT yield a percentage")
    XCTAssertEqual(usage.maxUsagePercent, 0)
    XCTAssertNil(usage.warning)
  }

  func testMissingCredentialsThrowsNotConfigured() async {
    let client = GoogleAntigravityClient(httpClient: MockGoogleHTTP(tokenResponse: "{}", modelsResponse: "{}"))
    let unconfigured = ProviderRuntimeConfiguration(
      accountID: "google-test",
      provider: .googleAntigravity,
      displayName: "Google Test",
      isEnabled: true,
      credentials: [:]
    )

    do {
      _ = try await client.fetchUsage(configuration: unconfigured, now: now)
      XCTFail("Expected notConfigured error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private final class MockGoogleHTTP: HTTPClient, @unchecked Sendable {
  let tokenResponse: String
  let modelsResponse: String

  init(tokenResponse: String, modelsResponse: String) {
    self.tokenResponse = tokenResponse
    self.modelsResponse = modelsResponse
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let urlString = request.url?.absoluteString ?? ""
    let body: String
    if urlString.contains("oauth2.googleapis.com") {
      body = tokenResponse
    } else {
      body = modelsResponse
    }

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(body.utf8), response)
  }
}
