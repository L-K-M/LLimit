import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class MiMoAccountTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!
  private var logs: [String] = []
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-mimo-accounts-\(UUID().uuidString)")
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
    logs = []
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
  }

  private func daemon() -> QuotaDaemon {
    let directory = self.directory!
    let daemon = QuotaDaemon(paths: paths, coordinator: .init(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) },
      environment: [:], log: { self.logs.append($0) })
    daemon.loadConfiguration()
    return daemon
  }

  private func add(to daemon: QuotaDaemon, userID: String = "42", token: String = "old-fixture") throws -> ProviderAccount {
    try daemon.editingSettings {
      try $0.addAccount(provider: .xiaomiMiMo, credentials: [
        CredentialField.mimoSessionCookies: "api-platform_serviceToken=\(token); userId=\(userID)"
      ])
    }
  }

  private func seedUsage(for accounts: [ProviderAccount]) throws -> QuotaSnapshot {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: accounts.map { account in
      ProviderUsage(accountID: account.id, provider: account.provider, title: account.resolvedDisplayName,
        metrics: [UsageMetric(id: "plan-total_token", label: "Plan credits", remainingPercent: 64)], fetchedAt: now)
    }, failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save([snapshot])
    return snapshot
  }

  func testAddAndUpdateKeepOnlyCanonicalCookiesInMemoryAndOnDisk() throws {
    let daemon = daemon()
    let raw = "Cookie: passToken=global-sso-fixture; userId=42; _onetrack_cid=analytics-fixture; api-platform_ph=csrf-fixture; api-platform_serviceToken=platform-fixture"
    let expected = [CredentialField.mimoSessionCookies: "api-platform_serviceToken=platform-fixture; api-platform_ph=csrf-fixture; userId=42"]
    let account = try daemon.editingSettings {
      try $0.addAccount(provider: .xiaomiMiMo, credentials: [CredentialField.mimoSessionCookies: raw])
    }
    XCTAssertEqual(account.credentials, expected)
    XCTAssertEqual(daemon.settings.accounts.first?.credentials, expected)
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().accounts.first?.credentials, expected)

    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mimoSessionCookies: "userId=42; passToken=another-global-fixture; api-platform_serviceToken=renewed-fixture; _onetrack_uid__mimo=another-analytics-fixture"
      ]))
    }
    let renewed = [CredentialField.mimoSessionCookies: "api-platform_serviceToken=renewed-fixture; userId=42"]
    XCTAssertEqual(updated.credentials, renewed)
    XCTAssertEqual(daemon.settings.accounts.first?.credentials, renewed)
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().accounts.first?.credentials, renewed)
    let saved = String(decoding: try Data(contentsOf: paths.settingsFileURL), as: UTF8.self)
    for excluded in ["passToken", "global-fixture", "_onetrack", "analytics-fixture"] {
      XCTAssertFalse(saved.contains(excluded))
      XCTAssertFalse(logs.joined().contains(excluded))
    }
    XCTAssertTrue(daemon.settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
  }

  func testInvalidHeaderEditsPreserveDurableSettingsMemorySnapshotAndHistory() throws {
    let daemon = daemon()
    let account = try add(to: daemon)
    let snapshot = try seedUsage(for: [account])
    let settings = try Data(contentsOf: paths.settingsFileURL)
    let history = try Data(contentsOf: paths.historyFileURL)
    for header in ["api-platform_serviceToken=invalid-fixture", "api-platform_serviceToken=invalid-fixture; userId=42; userId=43"] {
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.mimoSessionCookies: header]))
      }) { error in
        XCTAssertFalse(error.localizedDescription.contains("invalid-fixture"))
      }
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), settings)
      XCTAssertEqual(daemon.settings.accounts.first?.credentials, account.credentials)
      XCTAssertEqual(daemon.snapshot, snapshot)
      XCTAssertEqual(try SnapshotStore(fileURL: paths.snapshotFileURL).load(), snapshot)
      XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    }
  }

  func testSameUserSessionRenewalPreservesHistory() throws {
    let daemon = daemon()
    let account = try add(to: daemon)
    _ = try seedUsage(for: [account])
    let history = try Data(contentsOf: paths.historyFileURL)
    try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mimoSessionCookies: "api-platform_serviceToken=renewed-fixture; userId=42"
      ]))
    }
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    XCTAssertFalse(daemon.snapshot?.providers.contains { $0.accountID == account.id } ?? true)
  }

  func testDifferentUserPurgesOnlyThatAccountsSnapshotAndHistory() throws {
    let daemon = daemon()
    let account = try add(to: daemon)
    let peer = try add(to: daemon, userID: "99", token: "peer-fixture")
    _ = try seedUsage(for: [account, peer])
    try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mimoSessionCookies: "api-platform_serviceToken=other-user-fixture; userId=43"
      ]))
    }
    let saved = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load())
    XCTAssertEqual(saved.providers.map(\.accountID), [peer.id])
    XCTAssertEqual(daemon.snapshot?.providers.map(\.accountID), [peer.id])
    let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load()
    XCTAssertEqual(history.flatMap(\.providers).map(\.accountID), [peer.id])
    let output = StatusRenderer.waybarJSON(snapshot: saved, now: now)
    XCTAssertFalse(output.contains("other-user-fixture"))
    XCTAssertFalse(output.contains("peer-fixture"))
    XCTAssertFalse(output.contains(CredentialField.mimoSessionCookies))
  }

  func testMissingOrUnparseablePreviousIdentityPurgesHistoryConservatively() throws {
    for previous: [String: String] in [[:], [CredentialField.mimoSessionCookies: "legacy-invalid-fixture"]] {
      let account = ProviderAccount(id: "legacy-mimo", provider: .xiaomiMiMo, credentials: previous)
      // Legacy settings may predate save-time cookie validation. Keep this
      // fixture independent of the current SettingsStore write boundary.
      try FileManager.default.createDirectory(at: paths.settingsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(AppSettings(accounts: [account])).write(to: paths.settingsFileURL)
      _ = try seedUsage(for: [account])
      let daemon = daemon()
      try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([
          CredentialField.mimoSessionCookies: "api-platform_serviceToken=known-user-fixture; userId=42"
        ]))
      }
      XCTAssertFalse(try QuotaHistoryStore(fileURL: paths.historyFileURL).load().flatMap(\.providers).contains { $0.accountID == account.id })
      XCTAssertFalse(daemon.snapshot?.providers.contains { $0.accountID == account.id } ?? true)
    }
  }

  func testPendingMiMoAccountAndOtherProviderUpdatesKeepTheirExistingContracts() throws {
    let daemon = daemon()
    let pending = try daemon.editingSettings { try $0.addAccount(provider: .xiaomiMiMo) }
    XCTAssertEqual(pending.credentials, [CredentialField.mimoSessionCookies: ""])
    let kimi = try daemon.editingSettings {
      try $0.addAccount(provider: .kimi, credentials: [CredentialField.kimiAPIKey: "kimi-old-fixture"])
    }
    _ = try seedUsage(for: [kimi])
    let history = try Data(contentsOf: paths.historyFileURL)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(kimi.id, credentials: .merging([CredentialField.kimiAPIKey: "kimi-new-fixture"]))
    }
    XCTAssertEqual(updated.credentials[CredentialField.kimiAPIKey], "kimi-new-fixture")
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: pending.id)?.credentials,
                   [CredentialField.mimoSessionCookies: ""])
  }

  func testEnvironmentPointersSurviveAddAndUpdateWithoutResolution() throws {
    let daemon = daemon()
    let account = try daemon.editingSettings {
      try $0.addAccount(provider: .xiaomiMiMo, credentials: [
        CredentialField.mimoSessionCookies: "env:MIMO_COOKIES"
      ])
    }
    XCTAssertEqual(account.credentials, [CredentialField.mimoSessionCookies: "env:MIMO_COOKIES"])
    XCTAssertEqual(daemon.settings.accounts.first?.credentials, account.credentials)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mimoSessionCookies: "env:MIMO_WORK_COOKIES"
      ]))
    }
    let expected = [CredentialField.mimoSessionCookies: "env:MIMO_WORK_COOKIES"]
    XCTAssertEqual(updated.credentials, expected)
    XCTAssertEqual(daemon.settings.accounts.first?.credentials, expected)
    XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().accounts.first?.credentials, expected)
    let saved = try Data(contentsOf: paths.settingsFileURL)
    XCTAssertThrowsError(try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.mimoSessionCookies: "env:INVALID-NAME"
      ]))
    })
    XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), saved)
    XCTAssertEqual(daemon.settings.accounts.first?.credentials, expected)
  }
}
