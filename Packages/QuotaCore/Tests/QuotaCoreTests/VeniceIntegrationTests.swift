import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VeniceIntegrationTests: XCTestCase {
  func testCoordinatorKeepsVeniceAccountsSeparateAndRedactsCredentials() async throws {
    // These are inert sentinels consumed exclusively by the mock below.
    let accounts = ["personal", "work"].map { name in
      ProviderAccount(id: "venice-\(name)", provider: .venice, displayName: "Venice \(name)",
                      credentials: [CredentialField.veniceAPIKey: "fixture-\(name)"])
    }
    let settings = AppSettings(accounts: accounts)
    let snapshot = await QuotaCoordinator.live(httpClient: VeniceAccountHTTP()).refresh(
      configurations: accounts.map {
        ProviderRuntimeConfiguration(accountID: $0.id, provider: $0.provider,
                                     displayName: $0.resolvedDisplayName, isEnabled: true,
                                     credentials: $0.credentials)
      }, now: Date(timeIntervalSince1970: 1_790_000_000)
    )
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.map(\.accountID), ["venice-personal", "venice-work"])
    XCTAssertEqual(snapshot.providers.map { $0.metrics.first?.remainingPercent }, [80, 30])
    XCTAssertTrue(settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.accounts, accounts)
    let snapshotJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    XCTAssertFalse(snapshotJSON.contains("fixture-personal"))
    XCTAssertFalse(snapshotJSON.contains("fixture-work"))
  }
}

private struct VeniceAccountHTTP: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let remaining: Int
    switch request.value(forHTTPHeaderField: "Authorization") {
    case "Bearer fixture-personal": remaining = 80
    case "Bearer fixture-work": remaining = 30
    default: throw ProviderClientError(kind: .auth, message: "Unexpected fixture account")
    }
    let body: String
    if request.url?.path == "/api/v1/billing/balance" {
      body = #"{"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":\#(remaining),"usd":5},"diemEpochAllocation":100}"#
    } else {
      body = #"{"data":{"accessPermitted":true,"apiTier":{"id":"paid","isCharged":true},"balances":{"DIEM":\#(remaining),"USD":5},"nextEpochBegins":"2026-10-01T00:00:00Z","rateLimits":[]}}"#
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
  }
}
