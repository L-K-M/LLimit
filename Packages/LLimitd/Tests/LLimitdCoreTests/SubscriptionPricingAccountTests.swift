import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class SubscriptionPricingAccountTests: XCTestCase {
  private var directory: URL!
  private var paths: LinuxPaths!
  private var daemon: QuotaDaemon!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
    daemon = QuotaDaemon(paths: paths, coordinator: QuotaCoordinator(clients: []),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.directory], environment: [:]) },
      environment: [:], log: { _ in })
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    daemon = nil
    paths = nil
    directory = nil
    super.tearDown()
  }

  func testSetPriceAndRenameAreSavedInOneAccountEdit() throws {
    let account = try createAccount()
    try seedUsage(for: account)
    let historyBefore = try Data(contentsOf: paths.historyFileURL)
    let price = SubscriptionPricing(amount: 240, currency: "CHF", billingPeriod: .yearly)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, displayName: "Renamed subscription", subscriptionPricing: .set(price))
    }
    XCTAssertEqual(updated.displayName, "Renamed subscription")
    XCTAssertEqual(updated.subscriptionPricing, price)
    XCTAssertEqual(updated.credentials, account.credentials)
    let saved = try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)
    XCTAssertEqual(saved, updated)
    let snapshot = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load())
    XCTAssertEqual(snapshot.providers.first?.metrics.first?.remainingPercent, 70)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), historyBefore)
  }

  func testPriceOnlyEditPreservesQuotaBytesAndCredentials() throws {
    let account = try createAccount()
    try seedUsage(for: account)
    let snapshotBefore = try Data(contentsOf: paths.snapshotFileURL)
    let historyBefore = try Data(contentsOf: paths.historyFileURL)
    let updated = try daemon.editingSettings {
      try $0.updateAccount(account.id, subscriptionPricing: .set(SubscriptionPricing(amount: 20)))
    }
    XCTAssertEqual(updated.credentials, account.credentials)
    XCTAssertEqual(updated.subscriptionPricing?.amount, 20)
    XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), snapshotBefore)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), historyBefore)
  }

  func testZeroClearAndOldUpdateSignaturePreserveTheExpectedPricing() throws {
    let account = try createAccount()
    let zero = try daemon.editingSettings {
      try $0.updateAccount(account.id, subscriptionPricing: .set(SubscriptionPricing(amount: 0)))
    }
    XCTAssertEqual(zero.subscriptionPricing?.amount, 0)
    let renamed = try daemon.editingSettings { try $0.updateAccount(account.id, displayName: "Free subscription") }
    XCTAssertEqual(renamed.subscriptionPricing, zero.subscriptionPricing)
    let cleared = try daemon.editingSettings { try $0.updateAccount(account.id, subscriptionPricing: .set(nil)) }
    XCTAssertNil(cleared.subscriptionPricing)
    XCTAssertEqual(cleared.credentials, account.credentials)
    XCTAssertNil(try SettingsStore(fileURL: paths.settingsFileURL).load().account(withID: account.id)?.subscriptionPricing)
  }

  func testInvalidPriceRejectsTheWholeEditBeforeCredentialInvalidation() throws {
    let account = try createAccount()
    _ = try daemon.editingSettings {
      try $0.updateAccount(account.id, subscriptionPricing: .set(SubscriptionPricing(amount: 20)))
    }
    try seedUsage(for: account)
    let settingsBefore = try Data(contentsOf: paths.settingsFileURL)
    let snapshotBefore = try Data(contentsOf: paths.snapshotFileURL)
    let historyBefore = try Data(contentsOf: paths.historyFileURL)
    for pricing in [SubscriptionPricing(amount: -1), SubscriptionPricing(amount: .infinity),
                    SubscriptionPricing(amount: 10, currency: "usd")] {
      XCTAssertThrowsError(try daemon.editingSettings {
        try $0.updateAccount(account.id, displayName: "Must not persist",
          credentials: .merging([CredentialField.openAIAccessToken: "fixture-replacement"]), subscriptionPricing: .set(pricing))
      })
      XCTAssertEqual(try Data(contentsOf: paths.settingsFileURL), settingsBefore)
      XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), snapshotBefore)
      XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), historyBefore)
      XCTAssertEqual(daemon.settings.account(withID: account.id)?.credentials, account.credentials)
    }
  }

  func testTransactionReloadKeepsAConcurrentPriceWhenCredentialsAreUpdated() throws {
    let account = try createAccount()
    let original = daemon.settings
    var refreshed = original
    refreshed.accounts[0].credentials[CredentialField.openAIAccessToken] = "fixture-renewed"
    var edited = original
    let price = SubscriptionPricing(amount: 36, currency: "EUR", billingPeriod: .monthly)
    edited.accounts[0].subscriptionPricing = price
    let merged = QuotaDaemon.mergingCredentialChanges(base: original, current: refreshed, onto: edited)
    XCTAssertEqual(merged.account(withID: account.id)?.subscriptionPricing, price)
    XCTAssertEqual(merged.account(withID: account.id)?.credentials[CredentialField.openAIAccessToken], "fixture-renewed")
  }

  private func createAccount() throws -> ProviderAccount {
    try daemon.editingSettings {
      try $0.addAccount(provider: .openAI, displayName: "Fixture account", credentials: [CredentialField.openAIAccessToken: "fixture-original"])
    }
  }

  private func seedUsage(for account: ProviderAccount) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(accountID: account.id,
      provider: account.provider, title: account.resolvedDisplayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 70)], fetchedAt: now)], failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save([snapshot])
  }
}
