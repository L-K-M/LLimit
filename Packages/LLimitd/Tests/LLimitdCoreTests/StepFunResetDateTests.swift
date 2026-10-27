import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class StepFunResetDateTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-stepfun-reset-\(UUID().uuidString)")
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func daemon() -> QuotaDaemon {
    let directory = self.directory!
    let daemon = QuotaDaemon(paths: paths, coordinator: .init(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) }, environment: [:])
    daemon.loadConfiguration()
    return daemon
  }

  // MARK: - Plan-key account seeding

  private func seededPlanKey(resetAt: String? = nil, userID: String? = "123") throws -> (QuotaDaemon, ProviderAccount) {
    var creds = [CredentialField.stepFunPlanKey: "fixture-plan-key"]
    creds[CredentialField.stepFunUserID] = userID
    if let resetAt { creds[CredentialField.stepFunResetAt] = resetAt }
    let account = ProviderAccount(id: "stepfun-plan", provider: .stepFun, credentials: creds)
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [account]))
    let daemon = daemon()
    return (daemon, account)
  }

  // MARK: - Browser-session account seeding

  private func seededBrowser(resetAt: String? = nil, userID: String? = "123") throws -> (QuotaDaemon, ProviderAccount) {
    var creds = [
      CredentialField.stepFunSessionToken: "original-access",
      CredentialField.stepFunWebID: "original-device",
      CredentialField.stepFunBrowserSession: "private-browser-state"
    ]
    creds[CredentialField.stepFunUserID] = userID
    if let resetAt { creds[CredentialField.stepFunResetAt] = resetAt }
    let account = ProviderAccount(id: "stepfun-browser", provider: .stepFun, credentials: creds)
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [account]))
    let daemon = daemon()
    return (daemon, account)
  }

  // MARK: - Tests

  @discardableResult
  private func seedUsage(for accounts: [ProviderAccount]) throws -> QuotaSnapshot {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: accounts.map {
      ProviderUsage(accountID: $0.id, provider: .stepFun, title: $0.resolvedDisplayName,
        metrics: [UsageMetric(id: "monthly-credits", label: "Monthly plan credits", remainingPercent: 75)], fetchedAt: now)
    }, failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save([snapshot])
    return snapshot
  }

  func testValidResetDateRoundtripsThroughSettings() throws {
    for reset in ["2026-10-19", "2026-10-19T12:34:56.789Z", "2026-10-19T12:34:56+05:30"] {
      let (_, account) = try seededPlanKey(resetAt: reset)
      let saved = try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)
      XCTAssertEqual(saved?.credentials, account.credentials)
      XCTAssertFalse(try XCTUnwrap(account.provider.credentialFields.first { $0.key == CredentialField.stepFunResetAt }).isSecret)
    }
    let perms = try FileManager.default.attributesOfItem(atPath: paths.settingsFileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(perms?.intValue, 0o600)
  }

  func testInvalidResetDateRejectsAndPreservesSettings() throws {
    let (daemon, account) = try seededPlanKey()
    let snapshot = try seedUsage(for: [account])
    let settings = try Data(contentsOf: paths.settingsFileURL)
    let history = try Data(contentsOf: paths.historyFileURL)
    for bad in ["2026-02-30", "2026-00-01", "2026-13-01", "2026-10-19T00:00:00"] {
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.stepFunResetAt: bad]))
      })
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), settings)
      XCTAssertNil(daemon.settings.account(withID: account.id)?.credentials[CredentialField.stepFunResetAt])
      XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
      XCTAssertEqual(try SnapshotStore(fileURL: paths.snapshotFileURL).load(), snapshot)
      var invalid = account
      invalid.credentials[CredentialField.stepFunResetAt] = bad
      XCTAssertThrowsError(try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [invalid])))
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), settings)
    }
  }

  func testBlankResetDisablesWithoutAlteringAuthOrHistory() throws {
    let (daemon, account) = try seededPlanKey(resetAt: "2026-10-19")
    try seedUsage(for: [account])
    let historyData = try Data(contentsOf: paths.historyFileURL)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([CredentialField.stepFunResetAt: ""]))
    }
    XCTAssertNil(updated.credentials[CredentialField.stepFunResetAt])
    XCTAssertEqual(updated.credentials[CredentialField.stepFunPlanKey], "fixture-plan-key")
    XCTAssertEqual(updated.credentials[CredentialField.stepFunUserID], "123")
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), historyData)
    var blank = updated
    blank.credentials[CredentialField.stepFunResetAt] = " \n"
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [blank]))
    XCTAssertNil(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials[CredentialField.stepFunResetAt])
  }

  func testResetOnlyEditPreservesAllCredentialsAndInvalidatesSnapshot() throws {
    for userID in ["123", nil, ""] as [String?] {
      let (daemon, account) = try seededPlanKey(resetAt: "2026-10-19", userID: userID)
      try seedUsage(for: [account])
      let history = try Data(contentsOf: paths.historyFileURL)
      let updated = try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.stepFunResetAt: "2026-11-01"]))
      }
      var expected = account.credentials
      expected[CredentialField.stepFunResetAt] = "2026-11-01"
      XCTAssertEqual(updated.credentials, expected)
      XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.credentials, updated.credentials)
      XCTAssertFalse(daemon.snapshot?.providers.contains { $0.accountID == account.id } ?? false)
      XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    }
  }

  func testBrowserAccountResetEditPreservesBrowserState() throws {
    for userID in ["123", nil] as [String?] {
      let (daemon, account) = try seededBrowser(resetAt: "2026-10-19", userID: userID)
      try seedUsage(for: [account])
      let history = try Data(contentsOf: paths.historyFileURL)
      let updated = try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.stepFunResetAt: "2026-12-01"]))
      }
      var expected = account.credentials
      expected[CredentialField.stepFunResetAt] = "2026-12-01"
      XCTAssertEqual(updated.credentials, expected)
      XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
    }
  }

  func testReimportPreservesResetSetting() throws {
    let (daemon, account) = try seededPlanKey(resetAt: "2026-10-19")
    try seedUsage(for: [account])
    let history = try Data(contentsOf: paths.historyFileURL)
    let detected = DiscoveredCredential(stableID: "stepfun:step-code", provider: .stepFun,
      suggestedName: "StepFun", sourceLabel: "Step Code", credentials: [
        CredentialField.stepFunPlanKey: "replacement-fixture",
        CredentialField.stepFunUserID: "123"
      ])
    try daemon.editingSettings {
      _ = try $0.reimportAccount("stepfun-plan", among: [detected])
    }
    let saved = try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: "stepfun-plan")
    XCTAssertEqual(saved?.credentials[CredentialField.stepFunPlanKey], "replacement-fixture")
    XCTAssertEqual(saved?.credentials[CredentialField.stepFunResetAt], "2026-10-19")
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), history)
  }

  func testOldManualAuthEditDropsBrowserFieldsAndTargetHistory() throws {
    let (daemon, account) = try seededBrowser(resetAt: "2026-10-19")
    let peer = try daemon.editingSettings {
      try $0.addAccount(provider: .stepFun, displayName: "Peer", credentials: [
        CredentialField.stepFunPlanKey: "peer-key", CredentialField.stepFunUserID: "999"
      ])
    }
    try seedUsage(for: [account, peer])
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, credentials: .merging([
        CredentialField.stepFunSessionToken: "new-access", CredentialField.stepFunWebID: "new-device"
      ]))
    }
    XCTAssertNil(updated.credentials[CredentialField.stepFunBrowserSession])
    XCTAssertNil(updated.credentials[CredentialField.stepFunUserID])
    XCTAssertEqual(updated.credentials[CredentialField.stepFunResetAt], "2026-10-19")
    let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load()
    let retained = history.flatMap(\.providers).map(\.accountID)
    XCTAssertTrue(retained.contains(peer.id))
    XCTAssertFalse(retained.contains(account.id))
  }

  func testResetIsEditableAndRedactedSettingsExcludeEveryCredential() throws {
    let (daemon, _) = try seededPlanKey(resetAt: "2026-10-19")
    let redacted = daemon.settings.redactedCredentials()
    let account = redacted.account(withID: "stepfun-plan")
    XCTAssertEqual(account?.credentials, [:])
    XCTAssertTrue(QuotaDaemon.editableCredentialKeys(of: try XCTUnwrap(daemon.settings.account(withID: "stepfun-plan"))).contains(CredentialField.stepFunResetAt))
    let json = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
    XCTAssertFalse(json.contains("fixture-plan-key"))
  }
}
