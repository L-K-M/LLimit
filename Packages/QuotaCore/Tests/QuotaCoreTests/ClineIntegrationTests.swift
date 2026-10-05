import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ClineIntegrationTests: XCTestCase {
  func testClinePassAndCreditsFlowThroughLiveCoordinator() async throws {
    let configuration = ProviderRuntimeConfiguration(
      accountID: "cline-personal", provider: .cline, displayName: "Cline", isEnabled: true,
      credentials: [CredentialField.clineAPIKey: "fixture-personal"]
    )
    let snapshot = await QuotaCoordinator.live(httpClient: ClineHTTP(remaining: 55))
      .refresh(configurations: [configuration], now: Date(timeIntervalSince1970: 1_790_000_000))

    XCTAssertTrue(snapshot.failures.isEmpty)
    let metrics = try XCTUnwrap(snapshot.providers.first?.metrics)
    XCTAssertEqual(metrics.map(\.id), ["five_hour", "weekly", "monthly", "credit-balance"])
    XCTAssertEqual(metrics.map(\.remainingPercent), [55, 15, 5, nil])
    XCTAssertEqual(snapshot.providers.first?.maxUsagePercent, 95)
    XCTAssertEqual(snapshot.providers.first?.warning, "High ClinePass usage")
  }

  func testCoordinatorKeepsClineAccountsSeparateAndRedactsCredentials() async throws {
    // These are inert sentinels consumed exclusively by the mock below.
    let accounts = ["personal", "work"].map { name in
      ProviderAccount(id: "cline-\(name)", provider: .cline, displayName: "Cline \(name)",
                      credentials: [CredentialField.clineAPIKey: "fixture-\(name)"])
    }
    let settings = AppSettings(accounts: accounts)
    let snapshot = await QuotaCoordinator.live(httpClient: ClineAccountHTTP()).refresh(
      configurations: accounts.map {
        ProviderRuntimeConfiguration(accountID: $0.id, provider: $0.provider,
                                     displayName: $0.resolvedDisplayName, isEnabled: true,
                                     credentials: $0.credentials)
      }, now: Date(timeIntervalSince1970: 1_790_000_000)
    )

    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.map(\.accountID), ["cline-personal", "cline-work"])
    XCTAssertEqual(snapshot.providers.map { $0.metrics.first?.remainingPercent }, [80, 30])
    XCTAssertTrue(settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.accounts, accounts)

    let snapshotJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    XCTAssertFalse(snapshotJSON.contains("fixture-personal"))
    XCTAssertFalse(snapshotJSON.contains("fixture-work"))
  }
}

private struct ClineHTTP: HTTPClient {
  let remaining: Int

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url?.path ?? ""
    let body: String
    if path.hasSuffix("/balance") {
      body = #"{"success":true,"data":{"userId":"usr-01FIXTURE","balance":4250000}}"#
    } else if path.hasSuffix("/plan/usage-limits") {
      body = #"""
      {"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":\#(100 - remaining)},
                                        {"type":"weekly","percentUsed":85},{"type":"monthly","percentUsed":95}]}}
      """#
    } else {
      body = #"{"success":true,"data":{"id":"usr-01FIXTURE","email":"dev@example.com"}}"#
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private struct ClineAccountHTTP: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let remaining: Int
    switch request.value(forHTTPHeaderField: "Authorization") {
    case "Bearer fixture-personal": remaining = 20
    case "Bearer fixture-work": remaining = 70
    default: throw ProviderClientError(kind: .auth, message: "Unexpected fixture account")
    }
    let path = request.url?.path ?? ""
    let body: String
    if path.hasSuffix("/balance") {
      body = #"{"success":true,"data":{"userId":"usr-01\#(remaining)","balance":4250000}}"#
    } else if path.hasSuffix("/plan/usage-limits") {
      body = #"{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":\#(remaining)}]}}"#
    } else {
      body = #"{"success":true,"data":{"id":"usr-01\#(remaining)","email":"dev@example.com"}}"#
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}