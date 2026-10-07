import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class StatusTemplateTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private var snapshot: QuotaSnapshot {
    .init(generatedAt: now, providers: [ProviderUsage(accountID: "claude-id", provider: .anthropic, title: "Claude", metrics: [
      UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 70, resetAt: now.addingTimeInterval(3_600)),
      UsageMetric(id: "seven_day", label: "7-day limit", remainingPercent: 30, resetAt: now.addingTimeInterval(2 * 86_400 + 3 * 3_600))
    ], fetchedAt: now.addingTimeInterval(-300))], failures: [])
  }

  func testEveryPlaceholderKindFilterAndUnknownBraces() {
    let all = "{id}|{name}|{provider}|{remaining}|{metric}|{kind}|{reset}|{class}|{age}|{stale}"
    XCTAssertEqual(StatusTemplate.render(all, snapshot: snapshot, kind: nil, separator: "", now: now), "claude-id|Claude|anthropic|30%|7-day limit|weekly|2d 3h|warning|5 min ago|")
    XCTAssertEqual(StatusTemplate.render("{remaining} {kind} {reset}", snapshot: snapshot, kind: .session, separator: "", now: now), "70% session 1h")
    XCTAssertEqual(StatusTemplate.render("{remaining} {metric}", snapshot: snapshot, kind: .monthly, separator: "", now: now), "n/a ")
    XCTAssertEqual(StatusTemplate.render("{nope} {name} {{name}} {name", snapshot: snapshot, kind: nil, separator: "", now: now), "{nope} Claude {Claude} {name")
    XCTAssertEqual(StatusTemplate.render("{name}", snapshot: nil, kind: nil, separator: "", now: now), "")
  }

  func testCutoffsEstimatesUnlimitedAndSingleLineValues() {
    for (percent, expected) in [(14, "critical"), (15, "warning"), (39, "warning"), (40, "ok")] {
      var snapshot = snapshot
      snapshot.providers[0].metrics = [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: percent)]
      XCTAssertEqual(StatusTemplate.render("{class}", snapshot: snapshot, kind: nil, separator: "", now: now), expected)
    }
    var snapshot = snapshot
    snapshot.providers[0].title = "Work\nTeam\tA"
    XCTAssertEqual(StatusTemplate.render(StatusTemplate.pickDefault, snapshot: snapshot, kind: nil, separator: "", now: now), "claude-id\tWork Team A")
    snapshot.providers[0].metrics = [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 64, estimatedTotal: 100)]
    XCTAssertEqual(StatusTemplate.render("{remaining}", snapshot: snapshot, kind: nil, separator: "", now: now), "≈64%")
    snapshot.providers[0].metrics = [UsageMetric(id: "plan", label: "Plan", isUnlimited: true)]
    XCTAssertEqual(StatusTemplate.render("{remaining}:{class}", snapshot: snapshot, kind: nil, separator: "", now: now), "unlimited:ok")
  }
}
