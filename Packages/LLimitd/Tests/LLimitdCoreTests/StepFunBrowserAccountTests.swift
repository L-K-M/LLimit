import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class StepFunBrowserAccountTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-stepfun-browser-\(UUID().uuidString)")
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func seeded() throws -> (QuotaDaemon, ProviderAccount) {
    let account = ProviderAccount(id: "stepfun-browser", provider: .stepFun, credentials: [
      CredentialField.stepFunSessionToken: "original-access", CredentialField.stepFunWebID: "original-device",
      CredentialField.stepFunBrowserSession: "private-browser-state", CredentialField.stepFunUserID: "123"
    ])
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [account]))
    let directory = self.directory!
    let daemon = QuotaDaemon(paths: paths, coordinator: .init(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) }, environment: [:])
    daemon.loadConfiguration()
    return (daemon, account)
  }

  func testChangingEitherManualFieldDropsThePreviousSavedIdentityAndGrant() throws {
    for key in [CredentialField.stepFunSessionToken, CredentialField.stepFunWebID] {
      let (daemon, account) = try seeded()
      let updated = try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([key: "replacement"]))
      }
      XCTAssertNil(updated.credentials[CredentialField.stepFunBrowserSession])
      XCTAssertNil(updated.credentials[CredentialField.stepFunUserID])
      XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials,
        updated.credentials)
    }
  }

  func testSavingTheSameManualValuePreservesTheSavedLogin() throws {
    let (daemon, account) = try seeded()
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([CredentialField.stepFunSessionToken: "original-access"]))
    }
    XCTAssertEqual(updated.credentials, account.credentials)
  }

  func testCLICannotInjectBrowserSessionOrVerifiedIdentity() throws {
    for key in [CredentialField.stepFunBrowserSession, CredentialField.stepFunUserID] {
      let (daemon, account) = try seeded()
      XCTAssertFalse(QuotaDaemon.editableCredentialKeys(of: account).contains(key))
      let before = try Data(contentsOf: paths.settingsFileURL)
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([key: "injected"]))
      })
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), before)
      XCTAssertEqual(daemon.settings.account(withID: account.id)?.credentials, account.credentials)
    }
  }
}
