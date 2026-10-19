import Foundation
import XCTest
@testable import QuotaCore
@testable import LLimitdCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class JunieIntegrationTests: XCTestCase {
  func testLiveRefreshPersistsAllowancesAndRendersCredentialFreePercentages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = LinuxPaths(
      configHome: directory.appendingPathComponent("config"),
      dataHome: directory.appendingPathComponent("data")
    )
    let http = JunieAccountHTTP()
    let daemon = QuotaDaemon(
      paths: paths,
      coordinator: .live(httpClient: http),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [directory], environment: [:]) },
      environment: ["JUNIE_API_KEY": "junie-env-fixture-secret"],
      log: { _ in }
    )
    daemon.loadConfiguration()
    let manual = try daemon.editingSettings {
      try $0.addAccount(provider: .junie, displayName: "Personal Junie", credentials: [
        CredentialField.junieAPIKey: "env:JUNIE_API_KEY"
      ])
    }
    let detected = DiscoveredCredential(
      stableID: "junie:fixture", provider: .junie, suggestedName: "Imported Junie",
      sourceLabel: "Junie CLI fixture", credentials: [CredentialField.junieAPIKey: "junie-import-fixture-secret"]
    )
    let imported = try daemon.editingSettings { try $0.importAccount(from: detected) }
    let importedCredentials = detected.credentials.merging([CredentialField.junieCreditAllowance: "10"]) { _, new in new }
    _ = try daemon.editingSettings {
      try $0.updateAccount(imported.id, credentials: .replacing(with: importedCredentials))
    }

    await daemon.refreshNow()

    let snapshot = try XCTUnwrap(daemon.snapshot)
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(Set(snapshot.providers.map(\.accountID)), [manual.id, imported.id])
    let personal = try XCTUnwrap(snapshot.providers.first { $0.accountID == manual.id })
    let work = try XCTUnwrap(snapshot.providers.first { $0.accountID == imported.id })
    XCTAssertEqual(personal.title, "Personal Junie")
    XCTAssertEqual(work.title, "Imported Junie")
    XCTAssertEqual(personal.metrics.first?.remainingAmount, 12.5)
    XCTAssertEqual(work.metrics.first?.remainingAmount, 4.25)
    XCTAssertEqual(personal.metrics.first?.remainingPercent, 36)
    XCTAssertEqual(work.metrics.first?.remainingPercent, 43)
    XCTAssertEqual(personal.maxUsagePercent, 64)
    XCTAssertEqual(work.maxUsagePercent, 57)
    XCTAssertEqual(personal.metrics.first?.usageLine, "12.5 credits / 35 credits")
    XCTAssertEqual(work.metrics.first?.usageLine, "4.25 USD / 10 USD")
    for usage in snapshot.providers {
      XCTAssertEqual(usage.provider, .junie)
      XCTAssertEqual(usage.metrics.count, 1)
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertEqual(metric.id, "credit-balance")
      XCTAssertEqual(metric.label, "30-day AI credits")
      XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .monthly)
      XCTAssertNil(metric.estimatedTotal)
      XCTAssertNil(metric.resetAt)
      XCTAssertNil(metric.resetIn)
      XCTAssertNil(metric.windowSeconds)
      XCTAssertNil(metric.paceEstimate)
    }

    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(Set(requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }), [
      "Bearer junie-env-fixture-secret", "Bearer junie-import-fixture-secret"
    ])
    for request in requests {
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.absoluteString, "https://ingrazzio-cloud-prod.labs.jb.gg/auth/test")
    }

    let settings = try SettingsStore(fileURL: paths.settingsFileURL).load()
    XCTAssertEqual(settings.accounts.map(\.id), [manual.id, imported.id])
    XCTAssertEqual(settings.accounts.map(\.provider), [.junie, .junie])
    XCTAssertEqual(settings.accounts.map(\.resolvedDisplayName), ["Personal Junie", "Imported Junie"])
    XCTAssertTrue(settings.accounts.allSatisfy(\.isEnabled))
    XCTAssertEqual(settings.accounts[0].credentials, [
      CredentialField.junieAPIKey: "env:JUNIE_API_KEY",
      CredentialField.junieCreditAllowance: ""
    ])
    XCTAssertEqual(settings.accounts[1].credentials, importedCredentials)
    XCTAssertTrue(settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.settingsFileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    let json = StatusRenderer.waybarJSON(snapshot: snapshot, now: snapshot.generatedAt)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(object["percentage"] as? Int, 36)
    let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
    XCTAssertEqual(accounts.count, 2)
    for account in accounts {
      XCTAssertEqual(account["provider"] as? String, "junie")
      let isPersonal = account["id"] as? String == manual.id
      let expectedRemaining = isPersonal ? 36 : 43
      XCTAssertEqual(account["remainingPercent"] as? Int, expectedRemaining)
      let metric = try XCTUnwrap((account["metrics"] as? [[String: Any]])?.first)
      XCTAssertEqual(metric["remainingPercent"] as? Int, expectedRemaining)
      XCTAssertEqual(metric["remainingAmount"] as? Double, isPersonal ? 12.5 : 4.25)
      XCTAssertEqual(metric["usageLine"] as? String, isPersonal ? "12.5 credits / 35 credits" : "4.25 USD / 10 USD")
      XCTAssertEqual(metric["window"] as? String, "monthly")
      XCTAssertNil(metric["resetAt"])
      XCTAssertNil(metric["estimated"])
    }
    let human = StatusRenderer.humanReadable(snapshot: snapshot, now: snapshot.generatedAt)
    XCTAssertTrue(human.contains("36%"))
    XCTAssertTrue(human.contains("43%"))
    for output in [json, human] {
      XCTAssertFalse(output.contains("junie-env-fixture-secret"))
      XCTAssertFalse(output.contains("junie-import-fixture-secret"))
    }

    let persistedSnapshot = try XCTUnwrap(SnapshotStore(fileURL: paths.snapshotFileURL).load())
    XCTAssertEqual(Set(persistedSnapshot.providers.map(\.accountID)), [manual.id, imported.id])
    XCTAssertEqual(persistedSnapshot.providers.first { $0.accountID == manual.id }?.metrics.first?.remainingPercent, 36)
    XCTAssertEqual(persistedSnapshot.providers.first { $0.accountID == imported.id }?.metrics.first?.remainingPercent, 43)
    let history = try QuotaHistoryStore(fileURL: paths.historyFileURL).load()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(Set(history[0].providers.map(\.accountID)), [manual.id, imported.id])
    for url in [paths.snapshotFileURL, paths.historyFileURL] {
      let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
      XCTAssertFalse(contents.contains("junie-env-fixture-secret"))
      XCTAssertFalse(contents.contains("junie-import-fixture-secret"))
      XCTAssertFalse(contents.contains(CredentialField.junieAPIKey))
      XCTAssertFalse(contents.contains(CredentialField.junieCreditAllowance))
    }
    let savedSettings = String(decoding: try Data(contentsOf: paths.settingsFileURL), as: UTF8.self)
    XCTAssertFalse(savedSettings.contains("junie-env-fixture-secret"))

    // Replacing authentication does not replace the user's subscription plan.
    _ = try daemon.editingSettings { try $0.reimportAccount(imported.id, among: [detected]) }
    XCTAssertEqual(daemon.settings.account(withID: imported.id)?.credentials[CredentialField.junieCreditAllowance], "10")

    // A denominator change must not look like consumption in existing history.
    _ = try daemon.editingSettings {
      try $0.updateAccount(manual.id, credentials: .merging([CredentialField.junieCreditAllowance: "70"]))
    }
    let resetHistory = try QuotaHistoryStore(fileURL: paths.historyFileURL).load()
    XCTAssertFalse(resetHistory.flatMap(\.providers).contains { $0.accountID == manual.id })
    XCTAssertTrue(resetHistory.flatMap(\.providers).contains { $0.accountID == imported.id })
    await daemon.refreshNow()
    XCTAssertEqual(daemon.snapshot?.providers.first { $0.accountID == manual.id }?.metrics.first?.remainingPercent, 18)
  }
}

private actor JunieAccountHTTP: HTTPClient {
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body: String
    switch request.value(forHTTPHeaderField: "Authorization") {
    case "Bearer junie-env-fixture-secret":
      body = #"{"active":true,"balanceLeft":1250000,"balanceUnit":"AI_CREDITS","licenseType":"AIPU"}"#
    case "Bearer junie-import-fixture-secret":
      body = #"{"active":true,"balanceLeft":4.25,"balanceUnit":"USD","licenseType":"PRO"}"#
    default:
      throw ProviderClientError(kind: .auth, message: "Unexpected fixture account")
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
  }
}
