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

  func testReplacingBrowserWithPlanKeyDropsConsoleCredentialsAndIdentity() throws {
    let (daemon, account) = try seeded()
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([CredentialField.stepFunPlanKey: "fixture-plan-key"]))
    }
    XCTAssertEqual(updated.credentials[CredentialField.stepFunPlanKey], "fixture-plan-key")
    for key in [CredentialField.stepFunSessionToken, CredentialField.stepFunWebID,
                CredentialField.stepFunBrowserSession, CredentialField.stepFunUserID] {
      XCTAssertNil(updated.credentials[key])
    }
    let console = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.stepFunSessionToken: "fixture-console", CredentialField.stepFunWebID: "fixture-device"
      ]))
    }
    XCTAssertNil(console.credentials[CredentialField.stepFunPlanKey])
    XCTAssertEqual(console.credentials[CredentialField.stepFunSessionToken], "fixture-console")
  }

  func testImportedPlanKeyIsOwnedAndRecognizedWithoutCLI() throws {
    let (daemon, _) = try seeded()
    let detected = DiscoveredCredential(stableID: "stepfun:step-code", provider: .stepFun,
      suggestedName: "StepFun", sourceLabel: "Step Code", credentials: [
        CredentialField.stepFunPlanKey: "fixture-plan-key", CredentialField.stepFunUserID: "123"
      ])
    let imported = try daemon.editingSettings { try $0.importAccount(from: detected) }
    XCTAssertTrue(imported.hasRequiredCredentials)
    XCTAssertTrue(daemon.isDetectedCredentialImported(detected))
    let saved = try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: imported.id)
    XCTAssertEqual(saved?.credentials[CredentialField.stepFunPlanKey], "fixture-plan-key")
    XCTAssertEqual(saved?.credentials[CredentialField.stepFunUserID], "123")
    let permissions = try FileManager.default.attributesOfItem(atPath: paths.settingsFileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testReimportPreservesHistoryOnlyForTheSameKnownAccount() throws {
    for userID in ["123", "456", nil] as [String?] {
      let (daemon, account) = try seeded()
      let now = Date()
      let previous = QuotaSnapshot(generatedAt: now, providers: [account.id, "peer"].map {
        ProviderUsage(accountID: $0, provider: .stepFun, title: "StepFun",
          metrics: [UsageMetric(id: "monthly-credits", label: "Monthly plan credits", remainingPercent: 75)], fetchedAt: now)
      }, failures: [])
      let history = QuotaHistoryStore(fileURL: paths.historyFileURL)
      try history.save([previous])
      var credentials = [CredentialField.stepFunPlanKey: "fixture-plan-key"]
      credentials[CredentialField.stepFunUserID] = userID
      let detected = DiscoveredCredential(stableID: "stepfun:step-code", provider: .stepFun,
        suggestedName: "StepFun", sourceLabel: "Step Code", credentials: credentials)
      try daemon.editingSettings {
        _ = try $0.reimportAccount(account.id, among: [detected])
      }
      let retained = try history.load().flatMap(\.providers).map(\.accountID)
      XCTAssertTrue(retained.contains("peer"))
      XCTAssertEqual(retained.contains(account.id), userID == "123")
    }
  }
}
