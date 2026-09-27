import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OpenCodeGoIntegrationTests: XCTestCase {
  func testLiveCoordinatorKeepsMultipleGoAccountsSeparate() async throws {
    let accounts = [
      ProviderAccount(id: "go-personal", provider: .openCodeGo, displayName: "Personal Go",
                      credentials: [CredentialField.openCodeGoAPIKey: "personal-fixture"]),
      ProviderAccount(id: "go-work", provider: .openCodeGo, displayName: "Work Go",
                      credentials: [CredentialField.openCodeGoAPIKey: "work-fixture"])
    ]
    let settings = AppSettings(accounts: accounts)
    let coordinator = QuotaCoordinator.live(httpClient: GoAccountHTTP())
    let configurations = settings.accounts.map {
      ProviderRuntimeConfiguration(accountID: $0.id, provider: $0.provider,
                                   displayName: $0.resolvedDisplayName, isEnabled: $0.isEnabled,
                                   credentials: $0.credentials)
    }
    let snapshot = await coordinator.refresh(configurations: configurations,
                                              now: Date(timeIntervalSince1970: 1_790_000_000))

    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.map(\.accountID), ["go-personal", "go-work"])
    XCTAssertEqual(snapshot.providers.map(\.title), ["Personal Go", "Work Go"])
    XCTAssertEqual(snapshot.providers.map { $0.metrics.first?.remainingPercent }, [80, 30])

    let redacted = settings.redactedCredentials()
    XCTAssertTrue(redacted.accounts.allSatisfy { $0.credentials.isEmpty })
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.accounts, accounts)
    let snapshotJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    XCTAssertFalse(snapshotJSON.contains("personal-fixture"))
    XCTAssertFalse(snapshotJSON.contains("work-fixture"))
  }
}

private struct GoAccountHTTP: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let used: Int
    switch request.value(forHTTPHeaderField: "Authorization") {
    case "Bearer personal-fixture": used = 20
    case "Bearer work-fixture": used = 70
    default: throw ProviderClientError(kind: .auth, message: "Unexpected fixture account")
    }
    let window = #"{"status":"ok","percent":\#(used),"resetsAt":"2026-10-01T00:00:00Z"}"#
    let body = #"{"usage":{"rolling":\#(window),"weekly":\#(window),"monthly":\#(window)}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
  }
}
