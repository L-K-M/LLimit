import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MistralAccountTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!
  private var logs: [String] = []
  private let now = Date(timeIntervalSince1970: 1_793_232_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-mistral-accounts-\(UUID().uuidString)")
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  private func daemon(coordinator: QuotaCoordinator = .init(clients: [])) -> QuotaDaemon {
    let directory = self.directory!
    let daemon = QuotaDaemon(paths: paths, coordinator: coordinator,
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) },
      environment: [:], log: { self.logs.append($0) })
    daemon.loadConfiguration()
    return daemon
  }

  private func browserCredentials(token: String = "owned-session-fixture", user: String = "user-fixture",
                                  organization: String = "organization-fixture") throws -> [String: String] {
    let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "ory_session_test", .value: token,
      .domain: ".mistral.ai", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
    return try MistralBrowserSession(cookies: [cookie], now: now).credentials(userID: user, organizationID: organization)
  }

  private func add(_ daemon: QuotaDaemon, credentials: [String: String]? = nil) throws -> ProviderAccount {
    let credentials = try credentials ?? browserCredentials()
    return try daemon.editingSettings { try $0.addAccount(provider: .mistral, credentials: credentials) }
  }

  private func seedUsage(_ accounts: [ProviderAccount]) throws -> QuotaSnapshot {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: accounts.map { account in
      ProviderUsage(accountID: account.id, provider: .mistral, title: account.resolvedDisplayName,
        metrics: [UsageMetric(id: "api-monthly", label: "Monthly API allowance", remainingPercent: 96)], fetchedAt: now)
    }, failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save([snapshot])
    return snapshot
  }

  func testAddNormalizesCookiesAndStoresOnlyOwnedAuthenticationWithMode600() throws {
    let daemon = daemon()
    let account = try add(daemon, credentials: [CredentialField.mistralSessionCookies:
      "ory_session_test=owned-session-fixture; csrftoken=csrf-fixture; _ga=analytics-fixture; passToken=unrelated-sso-fixture"])
    let expected = [CredentialField.mistralSessionCookies: "csrftoken=csrf-fixture; ory_session_test=owned-session-fixture"]
    XCTAssertEqual(account.credentials, expected)
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials, expected)
    let permissions = try FileManager.default.attributesOfItem(atPath: paths.settingsFileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let saved = String(decoding: try Data(contentsOf: paths.settingsFileURL), as: UTF8.self)
    for excluded in ["analytics-fixture", "unrelated-sso-fixture", "_ga", "passToken"] {
      XCTAssertFalse(saved.contains(excluded))
      XCTAssertFalse(logs.joined().contains(excluded))
    }
    XCTAssertEqual(daemon.settings.redactedCredentials().account(withID: account.id)?.credentials, [:])
  }

  func testInvalidAddAndUpdateLeaveDurableAccountSnapshotAndHistoryUntouched() throws {
    let daemon = daemon()
    let account = try add(daemon)
    let snapshot = try seedUsage([account])
    let settings = try Data(contentsOf: paths.settingsFileURL)
    let history = try Data(contentsOf: paths.historyFileURL)
    for invalid in ["csrftoken=invalid-fixture", "ory_session_test=first; ory_session_test=second",
                    "ory_session_test=invalid-fixture\r\nX-Injected: bad"] {
      XCTAssertThrowsError(try add(daemon, credentials: [CredentialField.mistralSessionCookies: invalid]))
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.mistralSessionCookies: invalid]))
      }) { error in XCTAssertFalse(error.localizedDescription.contains("invalid-fixture")) }
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), settings)
      XCTAssertEqual(daemon.settings.account(withID: account.id)?.credentials, account.credentials)
      XCTAssertEqual(try SnapshotStore(fileURL: paths.snapshotFileURL).load(), snapshot)
      XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    }
  }

  func testManualReplacementDropsSavedBrowserAndVerifiedIdentityAndOnlyItsHistory() throws {
    let daemon = daemon()
    let account = try add(daemon)
    let peer = try add(daemon, credentials: browserCredentials(token: "peer-session-fixture", user: "peer-user"))
    _ = try seedUsage([account, peer])
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mistralSessionCookies: "ory_session_test=replacement-session-fixture; _ga=discard-fixture"
      ]))
    }
    XCTAssertEqual(updated.credentials[CredentialField.mistralSessionCookies], "ory_session_test=replacement-session-fixture")
    for key in [CredentialField.mistralBrowserSession, CredentialField.mistralUserID, CredentialField.mistralOrganizationID] {
      XCTAssertNil(updated.credentials[key])
    }
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials, updated.credentials)
    let snapshot = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load())
    XCTAssertEqual(snapshot.providers.map(\.accountID), [peer.id])
    XCTAssertEqual(try QuotaHistoryStore(fileURL: paths.historyFileURL).load().flatMap(\.providers).map(\.accountID), [peer.id])
  }

  func testSavingIdenticalRawSessionPreservesSavedIdentityAndHistory() throws {
    let daemon = daemon()
    let account = try add(daemon)
    _ = try seedUsage([account])
    let history = try Data(contentsOf: paths.historyFileURL)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mistralSessionCookies: try XCTUnwrap(account.credentials[CredentialField.mistralSessionCookies])
      ]))
    }
    XCTAssertEqual(updated.credentials, account.credentials)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
  }

  func testEquivalentFormattedHeaderPreservesBoundIdentityBrowserAndHistory() throws {
    let daemon = daemon()
    let cookies = try [
      XCTUnwrap(HTTPCookie(properties: [.name: "ory_session_test", .value: "owned-session-fixture",
        .domain: ".mistral.ai", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])),
      XCTUnwrap(HTTPCookie(properties: [.name: "csrftoken", .value: "csrf-fixture",
        .domain: ".mistral.ai", .path: "/", .secure: "TRUE"]))
    ]
    let browser = try MistralBrowserSession(cookies: cookies, now: now)
    let account = try add(daemon, credentials: browser.credentials(userID: "user-fixture", organizationID: "organization-fixture"))
    _ = try seedUsage([account])
    let history = try Data(contentsOf: paths.historyFileURL)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mistralSessionCookies:
          "  ory_session_test=owned-session-fixture;  _ga=analytics-fixture;  csrftoken=csrf-fixture  "
      ]))
    }
    XCTAssertEqual(updated.credentials[CredentialField.mistralSessionCookies], browser.cookieHeader)
    XCTAssertEqual(updated.credentials[CredentialField.mistralBrowserSession], account.credentials[CredentialField.mistralBrowserSession])
    XCTAssertEqual(updated.credentials[CredentialField.mistralUserID], "user-fixture")
    XCTAssertEqual(updated.credentials[CredentialField.mistralOrganizationID], "organization-fixture")
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials, account.credentials)
  }

  func testCLISetCannotInjectHiddenBrowserOrIdentityFields() throws {
    let daemon = daemon()
    let account = try add(daemon)
    let before = try Data(contentsOf: paths.settingsFileURL)
    for key in [CredentialField.mistralBrowserSession, CredentialField.mistralUserID, CredentialField.mistralOrganizationID] {
      XCTAssertFalse(QuotaDaemon.editableCredentialKeys(of: account).contains(key))
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([key: "injected-fixture"]))
      })
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), before)
      XCTAssertEqual(daemon.settings.account(withID: account.id)?.credentials, account.credentials)
    }
    XCTAssertTrue(QuotaDaemon.editableCredentialKeys(of: account).contains(CredentialField.mistralSessionCookies))
  }

  func testTrustedReplacementRetainsHistoryOnlyWhenBothVerifiedIdentitiesMatch() throws {
    for identity in [("user-fixture", "organization-fixture"), ("other-user", "organization-fixture"),
                     ("user-fixture", "other-organization")] {
      let daemon = daemon()
      let account = try add(daemon)
      _ = try seedUsage([account])
      let replacement = try browserCredentials(token: "renewed-session-fixture", user: identity.0, organization: identity.1)
      _ = try daemon.editingSettings { try $0.updateAccount(account.id, credentials: .replacing(with: replacement)) }
      let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load().flatMap(\.providers)
      XCTAssertEqual(history.contains { $0.accountID == account.id }, identity.0 == "user-fixture" && identity.1 == "organization-fixture")
      try FileManager.default.removeItem(at: directory)
    }
  }

  func testUnverifiedSessionReplacementPurgesHistoryAndKeepsPendingAccountsValid() throws {
    let daemon = daemon()
    let account = try add(daemon, credentials: [CredentialField.mistralSessionCookies: "ory_session_test=unverified-old-fixture"])
    _ = try seedUsage([account])
    _ = try daemon.editingSettings { try $0.updateAccount(account.id, credentials: .replacing(with: [
      CredentialField.mistralSessionCookies: "ory_session_test=unverified-new-fixture"
    ])) }
    XCTAssertTrue(try QuotaHistoryStore(fileURL: paths.historyFileURL).load().flatMap(\.providers).isEmpty)
    let pending = try daemon.editingSettings { try $0.addAccount(provider: .mistral) }
    XCTAssertFalse(pending.hasRequiredCredentials)
    XCTAssertEqual(pending.credentials[CredentialField.mistralSessionCookies], "")
  }

  func testOfflineRefreshWritesCredentialFreeSnapshotHistoryAndStatus() async throws {
    let daemon = daemon(coordinator: .init(clients: [MistralAccountFixtureClient()]))
    let account = try add(daemon)
    await daemon.refreshNow()
    let snapshot = try XCTUnwrap(daemon.snapshot)
    XCTAssertEqual(snapshot.providers.first?.accountID, account.id)
    XCTAssertTrue(snapshot.failures.isEmpty)
    let output = StatusRenderer.waybarJSON(snapshot: snapshot, now: now)
    for secret in ["owned-session-fixture", CredentialField.mistralBrowserSession, CredentialField.mistralSessionCookies] {
      XCTAssertFalse(output.contains(secret))
      XCTAssertFalse(logs.joined().contains(secret))
      for path in [paths.snapshotFileURL, paths.historyFileURL] {
        XCTAssertFalse(String(decoding: try Data(contentsOf: path), as: UTF8.self).contains(secret))
      }
    }
  }
}

private struct MistralAccountFixtureClient: QuotaProviderClient {
  let provider: QuotaProvider = .mistral
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    ProviderUsage(accountID: configuration.accountID, provider: provider, title: configuration.displayName,
      metrics: [UsageMetric(id: "api-monthly", label: "Monthly API allowance", remainingPercent: 96)], fetchedAt: now)
  }
}
