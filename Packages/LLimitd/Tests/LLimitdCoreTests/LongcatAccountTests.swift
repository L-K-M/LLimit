import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class LongcatAccountTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-longcat-accounts-\(UUID().uuidString)")
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  private func daemon() -> QuotaDaemon {
    let directory = self.directory!
    let daemon = QuotaDaemon(paths: paths, coordinator: QuotaCoordinator(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) },
      environment: [:], log: { _ in })
    daemon.loadConfiguration()
    return daemon
  }

  private func add(_ daemon: QuotaDaemon, token: String = "fixture-secret", user: String = "123") throws -> ProviderAccount {
    try daemon.editingSettings {
      try $0.addAccount(provider: .longcat, credentials: [
        CredentialField.longcatSessionCookies: "owned_session_fixture=\(token)", CredentialField.longcatUserID: user
      ])
    }
  }

  private func seedUsage(_ accounts: [ProviderAccount]) throws {
    let now = Date(timeIntervalSince1970: 1_793_232_000)
    let snapshot = QuotaSnapshot(generatedAt: now, providers: accounts.map { account in
      ProviderUsage(accountID: account.id, provider: .longcat, title: account.resolvedDisplayName,
        metrics: [UsageMetric(id: "token-balance", label: "Tokens remaining", remainingPercent: 50,
          remainingAmount: 500_000, estimatedTotal: 1_000_000)], fetchedAt: now)
    }, failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save([snapshot])
  }

  func testAddCanonicalizesOwnedCookiesAndExcludesAnalyticsFromSettings() throws {
    let daemon = daemon()
    let account = try daemon.editingSettings {
      try $0.addAccount(provider: .longcat, credentials: [CredentialField.longcatSessionCookies:
        " owned_session_fixture=fixture-secret; _ga=analytics-fixture ", CredentialField.longcatUserID: "123"])
    }
    XCTAssertEqual(account.credentials[CredentialField.longcatSessionCookies], "owned_session_fixture=fixture-secret")
    XCTAssertEqual(account.credentials[CredentialField.longcatUserID], "123")
    let saved = try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)
    XCTAssertEqual(saved?.credentials, account.credentials)
    XCTAssertFalse(String(decoding: try Data(contentsOf: paths.settingsFileURL), as: UTF8.self).contains("analytics-fixture"))
    XCTAssertEqual(daemon.settings.redactedCredentials().account(withID: account.id)?.credentials, [:])
  }

  func testChangedManualCookiesDropVerifiedIdentityAndOnlyItsSnapshotAndHistory() throws {
    let daemon = daemon()
    let account = try add(daemon)
    let peer = try add(daemon, token: "peer-fixture-secret", user: "456")
    try seedUsage([account, peer])
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.longcatSessionCookies: "owned_session_fixture=replacement-fixture-secret"
      ]))
    }
    XCTAssertNil(updated.credentials[CredentialField.longcatUserID])
    XCTAssertNil(updated.credentials[CredentialField.longcatBrowserSession])
    XCTAssertEqual(updated.credentials[CredentialField.longcatSessionCookies], "owned_session_fixture=replacement-fixture-secret")
    XCTAssertEqual(try SnapshotStore(fileURL: paths.snapshotFileURL).load()?.providers.map(\.accountID), [peer.id])
    XCTAssertEqual(try QuotaHistoryStore(fileURL: paths.historyFileURL).load().flatMap(\.providers).map(\.accountID), [peer.id])
  }

  func testEquivalentManualHeaderPreservesVerifiedIdentityAndHistory() throws {
    let daemon = daemon()
    let account = try add(daemon)
    try seedUsage([account])
    let history = try Data(contentsOf: paths.historyFileURL)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.longcatSessionCookies: " owned_session_fixture=fixture-secret; _ga=discard-fixture "
      ]))
    }
    XCTAssertEqual(updated.credentials, account.credentials)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
  }

  func testTrustedReplacementRetainsHistoryOnlyForSameVerifiedAccount() throws {
    for user in ["123", "456"] {
      let daemon = daemon()
      let account = try add(daemon)
      try seedUsage([account])
      let updated = try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .replacing(with: [
          CredentialField.longcatSessionCookies: "owned_session_fixture=replacement-fixture-secret",
          CredentialField.longcatUserID: user
        ]))
      }
      XCTAssertEqual(updated.credentials[CredentialField.longcatUserID], user)
      XCTAssertTrue(try SnapshotStore(fileURL: paths.snapshotFileURL).load()?.providers.isEmpty == true)
      let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load().flatMap(\.providers)
      XCTAssertEqual(history.contains { $0.accountID == account.id }, user == "123")
      try FileManager.default.removeItem(at: directory)
    }
  }

  func testPendingAccountRetainsEmptyRequiredCookieFieldAndLocalSettingsMode600() throws {
    let daemon = daemon()
    let account = try daemon.editingSettings { try $0.addAccount(provider: .longcat) }
    XCTAssertFalse(account.hasRequiredCredentials)
    XCTAssertEqual(account.credentials[CredentialField.longcatSessionCookies], "")
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id), account)
    XCTAssertEqual(daemon.settings.redactedCredentials().account(withID: account.id)?.credentials, [:])
    let permissions = try FileManager.default.attributesOfItem(atPath: paths.settingsFileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testCLISetCannotInjectHiddenBrowserOrIdentityFields() throws {
    let daemon = daemon()
    let account = try daemon.editingSettings { try $0.addAccount(provider: .longcat) }
    let before = try Data(contentsOf: paths.settingsFileURL)
    XCTAssertTrue(QuotaDaemon.editableCredentialKeys(of: account).contains(CredentialField.longcatSessionCookies))
    for key in [CredentialField.longcatBrowserSession, CredentialField.longcatUserID] {
      XCTAssertFalse(QuotaDaemon.editableCredentialKeys(of: account).contains(key))
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([key: "injected-fixture"]))
      })
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), before)
      XCTAssertEqual(daemon.settings.account(withID: account.id), account)
    }
  }

  func testInvalidCookieAddAndUpdateLeaveDurableAccountUntouched() throws {
    let daemon = daemon()
    let account = try daemon.editingSettings { try $0.addAccount(provider: .longcat) }
    let before = try Data(contentsOf: paths.settingsFileURL)
    for invalid in ["not-a-cookie-pair", "invalid-fixture\r\nX-Injected: bad"] {
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.addAccount(provider: .longcat, credentials: [CredentialField.longcatSessionCookies: invalid])
      }) { error in XCTAssertFalse(error.localizedDescription.contains("invalid-fixture")) }
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.longcatSessionCookies: invalid]))
      })
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), before)
      XCTAssertEqual(daemon.settings.account(withID: account.id), account)
    }
  }
}
