import Foundation
import XCTest
@testable import QuotaCore

final class MiMoPersistenceTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-mimo-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testSettingsSaveRetainsOnlyCanonicalPlatformCookies() throws {
    let header = "Cookie: passToken=global-sso-fixture; _onetrack_cid=analytics-fixture; userId=42; api-platform_ph=csrf-fixture; api-platform_serviceToken=platform-fixture; api-platform_slh=slh-fixture"
    let expected = "api-platform_serviceToken=platform-fixture; api-platform_slh=slh-fixture; api-platform_ph=csrf-fixture; userId=42"
    let account = ProviderAccount(provider: .xiaomiMiMo, credentials: [
      CredentialField.mimoSessionCookies: header, "unrelatedSecret": "unrelated-fixture"
    ])
    let file = directory.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: file)
    try store.save(AppSettings(accounts: [account]))

    let saved = try store.load()
    XCTAssertEqual(saved.accounts.first?.credentials, [CredentialField.mimoSessionCookies: expected])
    let bytes = try Data(contentsOf: file)
    let text = String(decoding: bytes, as: UTF8.self)
    for excluded in ["passToken", "global-sso-fixture", "_onetrack_cid", "analytics-fixture", "unrelated-fixture"] {
      XCTAssertFalse(text.contains(excluded))
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testInvalidHeaderSaveDoesNotReplaceExistingSettings() throws {
    let file = directory.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: file)
    let valid = ProviderAccount(id: "personal", provider: .xiaomiMiMo, credentials: [
      CredentialField.mimoSessionCookies: "api-platform_serviceToken=old-fixture; userId=42"
    ])
    try store.save(AppSettings(accounts: [valid]))
    let before = try Data(contentsOf: file)
    for header in [
      "api-platform_serviceToken=new-fixture", "userId=42",
      "api-platform_serviceToken=new-fixture; userId=42; userId=43",
      "api-platform_serviceToken=new-fixture\n; userId=42"
    ] {
      var changed = valid
      changed.credentials[CredentialField.mimoSessionCookies] = header
      XCTAssertThrowsError(try store.save(AppSettings(accounts: [changed]))) { error in
        XCTAssertFalse(error.localizedDescription.contains("new-fixture"))
      }
      XCTAssertEqual(try Data(contentsOf: file), before)
      XCTAssertEqual(try store.load().accounts, [valid])
    }
  }

  func testRedactedSettingsStayEmptyWhenSavedToAnotherStore() throws {
    let settings = AppSettings(accounts: [ProviderAccount(provider: .xiaomiMiMo, credentials: [
      CredentialField.mimoSessionCookies: "api-platform_serviceToken=private-fixture; userId=42"
    ])])
    let redacted = settings.redactedCredentials()
    XCTAssertEqual(redacted.accounts.first?.credentials, [:])
    let file = directory.appendingPathComponent("widget-settings.json")
    let store = SettingsStore(fileURL: file)
    try store.save(redacted)
    XCTAssertEqual(try store.load().accounts.first?.credentials, [:])
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    XCTAssertFalse(text.contains("private-fixture"))
    XCTAssertFalse(text.contains(CredentialField.mimoSessionCookies))
  }

  func testPendingAccountsWithoutSessionAreAllowed() throws {
    let accounts = [
      ProviderAccount(id: "pending-empty", provider: .xiaomiMiMo),
      ProviderAccount(id: "pending-field", provider: .xiaomiMiMo,
        credentials: [CredentialField.mimoSessionCookies: ""])
    ]
    let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    try store.save(AppSettings(accounts: accounts))
    XCTAssertEqual(try store.load().accounts, accounts)
  }

  func testSessionIdentityUsesUserIDRatherThanToken() {
    let old = "api-platform_serviceToken=old-fixture; userId=42"
    let renewed = "api-platform_serviceToken=new-fixture; api-platform_ph=csrf-fixture; userId=42"
    let another = "api-platform_serviceToken=new-fixture; userId=43"
    XCTAssertFalse(MiMoSessionCookies.hasChangedIdentity(from: old, to: renewed))
    XCTAssertTrue(MiMoSessionCookies.hasChangedIdentity(from: old, to: another))
    for unknown: String? in [nil, "", "unparseable-fixture", "api-platform_serviceToken=old-fixture"] {
      XCTAssertTrue(MiMoSessionCookies.hasChangedIdentity(from: unknown, to: renewed))
      XCTAssertTrue(MiMoSessionCookies.hasChangedIdentity(from: old, to: unknown))
    }
  }

  func testOtherProvidersCredentialsAreNotFilteredByMiMoRules() throws {
    let credentials = [CredentialField.kimiAPIKey: "kimi-fixture", "custom-key": "custom-fixture"]
    let account = ProviderAccount(provider: .kimi, credentials: credentials)
    let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    try store.save(AppSettings(accounts: [account]))
    XCTAssertEqual(try store.load().accounts.first?.credentials, credentials)
  }

  func testEnvironmentPointerPersistsWithoutReadingOrResolvingItsValue() throws {
    let file = directory.appendingPathComponent("settings.json")
    let store = SettingsStore(fileURL: file)
    let credentials = [CredentialField.mimoSessionCookies: "env:MIMO_COOKIES"]
    let account = ProviderAccount(provider: .xiaomiMiMo, credentials: credentials)
    try store.save(AppSettings(accounts: [account]))
    XCTAssertEqual(try store.load().accounts.first?.credentials, credentials)
    let saved = try Data(contentsOf: file)
    let malformed = ProviderAccount(provider: .xiaomiMiMo, credentials: [
      CredentialField.mimoSessionCookies: "env:INVALID-NAME"
    ])
    XCTAssertThrowsError(try store.save(AppSettings(accounts: [malformed])))
    XCTAssertEqual(try Data(contentsOf: file), saved)
  }
}
