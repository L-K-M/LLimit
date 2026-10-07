import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class GoogleAntigravityClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testMissingMalformedAndOutOfRangeFractionsRemainUnknown() async throws {
    for fraction in [nil, "null", "true", #""n/a""#, "-0.1", "1.5"] {
      let field = fraction.map { "\"remainingFraction\":\($0)," } ?? ""
      let usage = try await fetch(#"{"models":{"gemini-3-flash":{"quotaInfo":{\#(field)"resetTime":"2023-11-15T10:00:00Z"}}}}"#)
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertNil(metric.remainingPercent)
      XCTAssertNotNil(metric.resetAt)
      XCTAssertNil(usage.maxUsagePercent)
      XCTAssertNil(usage.warning)
    }
  }

  func testOnlyReadableFractionsDriveAggregateUsage() async throws {
    let usage = try await fetch(#"{"models":{"gemini-3-pro-high":{"quotaInfo":{"remainingFraction":0.64}},"gemini-3-flash":{"quotaInfo":{}},"claude-opus-4-5-thinking":{}}}"#)
    XCTAssertEqual(usage.metrics.count, 3)
    XCTAssertEqual(usage.metrics.first { $0.id == "gemini-3-pro-high" }?.remainingPercent, 64)
    XCTAssertNil(usage.metrics.first { $0.id == "gemini-3-flash" }?.remainingPercent)
    XCTAssertEqual(usage.maxUsagePercent, 36)
    XCTAssertNil(usage.warning)
  }

  private func fetch(_ body: String) async throws -> ProviderUsage {
    try await GoogleAntigravityClient(httpClient: AntigravityFixtureHTTP(body: body)).fetchUsage(configuration: ProviderRuntimeConfiguration(
      provider: .googleAntigravity, isEnabled: true,
      credentials: [CredentialField.googleRefreshToken: "fixture-refresh", CredentialField.googleProjectID: "fixture-project", CredentialField.googleEmail: "user@example.com"]
    ), now: now)
  }
}

private struct AntigravityFixtureHTTP: HTTPClient {
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: HTTPStatusCode.ok, httpVersion: nil, headerFields: nil) else {
      throw URLError(.badURL)
    }
    let responseBody = url.host == "oauth2.googleapis.com" ? #"{"access_token":"fixture-access","expires_in":3600}"# : body
    return (Data(responseBody.utf8), response)
  }
}
