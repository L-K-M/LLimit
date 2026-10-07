import XCTest
@testable import QuotaCore

final class DashboardIntegrationCompatibilityTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let account = ProviderAccount(id: "work", provider: .openAI, displayName: "Current work name")

  func testFailureCooldownAndTitleSurviveCodecAndDashboardProjection() throws {
    let deadline = now.addingTimeInterval(120)
    let failure = ProviderFailure(accountID: account.id, provider: account.provider, kind: .rateLimit,
      message: "Try again later.", retryAt: deadline, title: "Stored name")
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [], failures: [failure], refreshIntervalMinutes: 60)
    let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(decoded.failures.first?.retryAt, deadline)
    XCTAssertEqual(decoded.failures.first?.title, "Stored name")
    XCTAssertEqual(decoded.refreshIntervalMinutes, 60)

    let dashboard = DashboardPresentation(settings: .loaded(AppSettings(accounts: [account])), snapshot: .loaded(decoded))
    XCTAssertEqual(dashboard.state, .allFailed)
    XCTAssertEqual(dashboard.failures.first?.title, account.resolvedDisplayName)
    XCTAssertEqual(dashboard.failures.first?.retryAt, deadline)
  }

  func testReportedDurationSurvivesProjectionAndFeedsPace() throws {
    let metric = UsageMetric(id: "reported-window", label: "Reported window", remainingPercent: 70,
      resetAt: now.addingTimeInterval(1_800), windowSeconds: 3_600)
    let usage = ProviderUsage(accountID: account.id, provider: account.provider, title: "Stored name",
      metrics: [metric], fetchedAt: now)
    let dashboard = DashboardPresentation(settings: .loaded(AppSettings(accounts: [account])),
      snapshot: .loaded(QuotaSnapshot(generatedAt: now, providers: [usage], failures: [])))
    let shown = try XCTUnwrap(dashboard.providers.first)
    let shownMetric = try XCTUnwrap(dashboardPrimaryMetric(for: shown))
    XCTAssertEqual(shown.title, account.resolvedDisplayName)
    XCTAssertEqual(shownMetric.windowSeconds, metric.windowSeconds)
    let pace = try XCTUnwrap(QuotaPace(metric: shownMetric, provider: shown.provider, fetchedAt: shown.fetchedAt, now: now))
    XCTAssertEqual(pace.evenPaceRemainingFraction, 0.5)
  }

  func testHistoryAccountRemovalKeepsCadenceAndReportedDuration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = QuotaHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    let kept = ProviderUsage(accountID: account.id, provider: account.provider, title: account.resolvedDisplayName,
      metrics: [UsageMetric(id: "reported-window", label: "Reported window", remainingPercent: 70, windowSeconds: 3_600)], fetchedAt: now)
    var removed = kept
    removed.accountID = "removed"
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [kept, removed], failures: [], refreshIntervalMinutes: 180)
    try store.save([snapshot])
    try store.remove(accountIDs: [removed.accountID])
    let remaining = try XCTUnwrap(store.load().first)
    XCTAssertEqual(remaining.providers, [kept])
    XCTAssertEqual(remaining.refreshIntervalMinutes, snapshot.refreshIntervalMinutes)
    XCTAssertEqual(QuotaFreshness.maxAge(refreshIntervalMinutes: remaining.refreshIntervalMinutes), 21_600)
  }
}
