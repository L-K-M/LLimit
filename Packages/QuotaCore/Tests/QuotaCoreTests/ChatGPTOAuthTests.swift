import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ChatGPTOAuthTests: XCTestCase {
  func testRefreshParsesTokensAndAccountID() async throws {
    let access = makeJWT(claims: [
      "exp": 4_102_444_800, // year 2100
      "https://api.openai.com/auth": ["chatgpt_account_id": "acct_123"]
    ])
    let json = #"{"access_token":"\#(access)","refresh_token":"rt_new","token_type":"bearer"}"#
    let result = try await ChatGPTOAuth.refresh(refreshToken: "rt_old", httpClient: MockHTTP(status: 200, body: json))

    XCTAssertEqual(result.accessToken, access)
    XCTAssertEqual(result.refreshToken, "rt_new")
    XCTAssertEqual(result.accountID, "acct_123")
  }

  func testRefreshFailureThrowsAuth() async {
    let client = MockHTTP(status: 400, body: #"{"error":"invalid_grant"}"#)
    do {
      _ = try await ChatGPTOAuth.refresh(refreshToken: "bad", httpClient: client)
      XCTFail("expected error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testExpiryDetection() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fresh = makeJWT(claims: ["exp": now.timeIntervalSince1970 + 3600])
    let stale = makeJWT(claims: ["exp": now.timeIntervalSince1970 + 60]) // within 5-min leeway

    XCTAssertFalse(ChatGPTOAuth.isAccessTokenExpired(fresh, now: now))
    XCTAssertTrue(ChatGPTOAuth.isAccessTokenExpired(stale, now: now))
    XCTAssertTrue(ChatGPTOAuth.isAccessTokenExpired("not-a-jwt", now: now))
  }

  // MARK: - Helpers

  private func makeJWT(claims: [String: Any]) -> String {
    let header = base64URL(["alg": "none", "typ": "JWT"])
    let payload = base64URL(claims)
    return "\(header).\(payload).sig"
  }

  private func base64URL(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

final class CredentialDiscoveryRefreshTokenTests: XCTestCase {
  func testCodexRefreshTokenCaptured() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-rt-\(UUID().uuidString)")
    let url = home.appendingPathComponent(".codex").appendingPathComponent("auth.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try #"{"tokens":{"access_token":"at","refresh_token":"rt","account_id":"acc"}}"#
      .data(using: .utf8)!.write(to: url)

    let creds = CredentialDiscovery(homeDirectories: [home]).discover().credentials
    let openai = creds.first { $0.provider == .openAI }
    XCTAssertEqual(openai?.credentials[CredentialField.openAIRefreshToken], "rt")
    XCTAssertEqual(openai?.credentials[CredentialField.openAIAccessToken], "at")
  }
}

private struct MockHTTP: HTTPClient {
  let status: Int
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (body.data(using: .utf8)!, response)
  }
}
