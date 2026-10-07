import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class EnvironmentCredentialTests: XCTestCase {
  private var root: URL!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func daemon(_ client: any QuotaProviderClient) -> QuotaDaemon {
    let daemon = QuotaDaemon(
      paths: LinuxPaths(configHome: root.appendingPathComponent("config"), dataHome: root.appendingPathComponent("data")),
      coordinator: QuotaCoordinator(clients: [client]),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.root]) },
      environment: ["FIRST_KEY": "first-resolved-secret", "SECOND_KEY": "second-resolved-secret"],
      log: { _ in })
    daemon.loadConfiguration()
    return daemon
  }

  func testUnchangedEnvironmentReferencePublishesUsageWithoutPersistingItsValue() async throws {
    let client = EnvironmentUsageClient()
    let daemon = daemon(client)
    let account = try daemon.editingSettings {
      try $0.addAccount(provider: .venice, credentials: [CredentialField.veniceAPIKey: "env:FIRST_KEY"])
    }

    await daemon.refreshNow()

    let calls = await client.credentials
    XCTAssertEqual(calls, [[CredentialField.veniceAPIKey: "first-resolved-secret"]])
    XCTAssertEqual(daemon.snapshot?.providers.first?.accountID, account.id)
    XCTAssertEqual(daemon.snapshot?.providers.first?.metrics.first?.remainingPercent, 73)
    XCTAssertEqual(daemon.settings.accounts.first?.credentials[CredentialField.veniceAPIKey], "env:FIRST_KEY")
    let saved = try SettingsStore(fileURL: daemon.paths.settingsFileURL).load()
    XCTAssertEqual(saved.accounts.first?.credentials[CredentialField.veniceAPIKey], "env:FIRST_KEY")
    for url in [daemon.paths.settingsFileURL, daemon.paths.snapshotFileURL, daemon.paths.historyFileURL] {
      XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("first-resolved-secret"))
    }
  }

  func testChangedResolvedCredentialRejectsTheInFlightResult() async throws {
    let client = EnvironmentUsageClient()
    let daemon = daemon(client)
    let account = try daemon.editingSettings {
      try $0.addAccount(provider: .venice, credentials: [CredentialField.veniceAPIKey: "env:FIRST_KEY"])
    }
    await client.beforeResult {
      _ = try daemon.editingSettings {
        try $0.updateAccount(account.id, credentials: .merging([CredentialField.veniceAPIKey: "env:SECOND_KEY"]))
      }
    }

    await daemon.refreshNow()

    XCTAssertTrue(daemon.snapshot?.providers.isEmpty == true)
    XCTAssertTrue(daemon.snapshot?.failures.isEmpty == true)
    let saved = try SettingsStore(fileURL: daemon.paths.settingsFileURL).load()
    XCTAssertEqual(saved.accounts.first?.credentials[CredentialField.veniceAPIKey], "env:SECOND_KEY")
    let calls = await client.credentials
    XCTAssertEqual(calls, [[CredentialField.veniceAPIKey: "first-resolved-secret"]])
  }
}

private actor EnvironmentUsageClient: QuotaProviderClient {
  let provider: QuotaProvider = .venice
  private(set) var credentials: [[String: String]] = []
  private var edit: (() throws -> Void)?

  func beforeResult(_ edit: @escaping () throws -> Void) {
    self.edit = edit
  }

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    credentials.append(configuration.credentials)
    try edit?()
    return ProviderUsage(
      accountID: configuration.accountID, provider: provider, title: "Venice",
      metrics: [UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: 73)], fetchedAt: now)
  }
}
