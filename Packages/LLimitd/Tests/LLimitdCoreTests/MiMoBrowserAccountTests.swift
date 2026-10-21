import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class MiMoBrowserAccountTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!
  private let reset = "2026-10-19T20:14:00Z"

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-mimo-browser-\(UUID().uuidString)")
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func seeded(browser: Bool = true) throws -> (QuotaDaemon, ProviderAccount) {
    let json = """
    [{"name":"passToken","value":"saved-login-fixture","domain":".account.xiaomi.com","path":"/","secure":true,"httpOnly":true},
     {"name":"userId","value":"42","domain":".account.xiaomi.com","path":"/","secure":true,"httpOnly":true}]
    """
    var credentials = [CredentialField.mimoSessionCookies: "api-platform_serviceToken=console-fixture; userId=42",
                       CredentialField.mimoResetAt: reset]
    if browser { credentials[CredentialField.mimoBrowserSession] = try MiMoBrowserSession(serialized: json).encoded() }
    let account = ProviderAccount(id: "fixture-mimo", provider: .xiaomiMiMo, credentials: credentials)
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [account]))
    let directory = self.directory!
    let daemon = QuotaDaemon(paths: paths, coordinator: .init(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) }, environment: [:])
    daemon.loadConfiguration()
    return (daemon, account)
  }

  func testManualConsoleReplacementDropsBrowserLoginAndPreservesPurchaseSetting() throws {
    let console = [CredentialField.mimoSessionCookies: "api-platform_serviceToken=replacement-fixture; userId=42"]
    for change in [CredentialChange.merging(console), .replacing(with: console)] {
      let (daemon, account) = try seeded()
      let updated = try daemon.editingSettings { try $0.updateAccount(account.id, credentials: change) }
      XCTAssertNil(updated.credentials[CredentialField.mimoBrowserSession])
      XCTAssertEqual(updated.credentials[CredentialField.mimoResetAt], reset)
      XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials, updated.credentials)
    }
  }

  func testResetOnlyEditPreservesSavedLoginAcrossReloadAndRedactsSharedSettings() throws {
    let (daemon, account) = try seeded()
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([CredentialField.mimoResetAt: "2026-10-20"]))
    }
    XCTAssertEqual(updated.credentials[CredentialField.mimoBrowserSession], account.credentials[CredentialField.mimoBrowserSession])
    let saved = try SettingsStore(fileURL: paths.settingsFileURL).load()
    XCTAssertEqual(saved.account(withID: account.id)?.credentials, updated.credentials)
    let shared = String(decoding: try JSONEncoder().encode(saved.redactedCredentials()), as: UTF8.self)
    XCTAssertFalse(shared.contains("saved-login-fixture"))
    XCTAssertFalse(shared.contains(CredentialField.mimoBrowserSession))
  }

  func testSavedBrowserSecretIsNeverAnEditableCLIOrMergingKey() throws {
    for hasBrowser in [true, false] {
      let (daemon, account) = try seeded(browser: hasBrowser)
      // --set validates against this same public set before opening its write transaction.
      XCTAssertFalse(QuotaDaemon.editableCredentialKeys(of: account).contains(CredentialField.mimoBrowserSession))
      let before = try Data(contentsOf: paths.settingsFileURL)
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.mimoBrowserSession: "replacement-fixture"]))
      }) { error in
        guard case DaemonError.unknownCredentialKey(let key, _) = error else { return XCTFail("Expected hidden-key rejection") }
        XCTAssertEqual(key, CredentialField.mimoBrowserSession)
      }
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), before)
      XCTAssertEqual(daemon.settings.account(withID: account.id)?.credentials, account.credentials)
    }
  }
}
