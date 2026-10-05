import XCTest
@testable import QuotaCore

final class ProviderMetricSelectionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testClaudeSelectionIsStableRegardlessOfResponseOrder() {
    let usage = makeUsage(
      provider: .anthropic,
      metrics: [
        metric("seven_day_opus"),
        metric("seven_day"),
        metric("five_hour")
      ]
    )

    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five_hour", "seven_day"])
  }

  func testCopilotFallsBackThroughKnownMetricOrder() {
    let usage = makeUsage(
      provider: .gitHubCopilot,
      metrics: [metric("completions"), metric("chat")]
    )

    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["chat", "completions"])
  }

  func testDefaultsCoverEveryProvider() {
    let cases: [(QuotaProvider, [String], [String])] = [
      (.anthropic, ["seven_day", "five_hour"], ["five_hour", "seven_day"]),
      (.openAI, ["secondary", "primary"], ["primary", "secondary"]),
      (.zhipu, ["mcp", "tokens"], ["tokens", "mcp"]),
      (.zai, ["mcp", "tokens"], ["tokens", "mcp"]),
      (.gitHubCopilot, ["completions", "premium", "chat"], ["premium", "chat"]),
      (.googleAntigravity, ["gemini-3-flash", "gemini-3-pro-high"], ["gemini-3-pro-high", "gemini-3-flash"])
    ]

    for (provider, inputIDs, expectedIDs) in cases {
      let usage = makeUsage(provider: provider, metrics: inputIDs.map { metric($0) })
      XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), expectedIDs, provider.rawValue)
    }
  }

  func testSelectionFiltersUnknownValuesAndSupportsOneRing() {
    let usage = makeUsage(
      provider: .openAI,
      metrics: [
        UsageMetric(id: "unknown", label: "Unknown"),
        metric("primary")
      ]
    )

    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["primary"])
  }

  func testSelectionUsesBoundedUnknownMetricAsFallback() {
    let usage = makeUsage(provider: .openAI, metrics: [metric("workspace")])

    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["workspace"])
  }

  func testSelectionSupportsUnlimitedAndEmptyMetrics() {
    let unlimited = UsageMetric(id: "primary", label: "Primary", isUnlimited: true)
    let empty = UsageMetric(id: "secondary", label: "Secondary")

    XCTAssertEqual(
      defaultRingMetrics(for: makeUsage(provider: .openAI, metrics: [empty, unlimited])).map(\.id),
      ["primary"]
    )
    XCTAssertTrue(defaultRingMetrics(for: makeUsage(provider: .openAI, metrics: [empty])).isEmpty)
  }

  func testOpenCodeGoShowsShortestAndLongestWindows() {
    let usage = makeUsage(
      provider: .openCodeGo,
      metrics: [metric("weekly"), metric("monthly"), metric("session-rolling")]
    )

    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["session-rolling", "monthly"])
    XCTAssertEqual(primaryLimitSlot(for: usage.metrics)?.kind, .monthly)

    let withoutMonthly = makeUsage(provider: .openCodeGo, metrics: [metric("weekly"), metric("session-rolling")])
    XCTAssertEqual(defaultRingMetrics(for: withoutMonthly).map(\.id), ["session-rolling", "weekly"])
  }

  func testShortTermKindsCoverSubDailyWindows() {
    XCTAssertTrue(QuotaWindowKind.session.isShortTerm)
    XCTAssertTrue(QuotaWindowKind.daily.isShortTerm)
    XCTAssertFalse(QuotaWindowKind.weekly.isShortTerm)
    XCTAssertFalse(QuotaWindowKind.monthly.isShortTerm)
    XCTAssertFalse(QuotaWindowKind.other.isShortTerm)
  }

  func testVeniceUsesDailyDIEMForRingsAndPrimaryColor() {
    let usage = makeUsage(provider: .venice, metrics: [
      UsageMetric(id: "usd-balance", label: "USD balance", usedDisplay: "$12.50"),
      UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: 65),
      UsageMetric(id: "bundled-credits", label: "Bundled credits", usedDisplay: "$5.00")
    ])
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["daily-diem"])
    XCTAssertEqual(primaryLimitSlot(for: usage.metrics)?.kind, .daily)
    XCTAssertTrue(chartsAsLongTermLimit(.daily, accountKinds: [.daily]))
  }

  func testVeniceBalancesNeverInventQuotaRings() {
    let usage = makeUsage(provider: .venice, metrics: [
      UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", usedDisplay: "25 DIEM"),
      UsageMetric(id: "usd-balance", label: "USD balance", usedDisplay: "$12.50")
    ])
    XCTAssertTrue(defaultRingMetrics(for: usage).isEmpty)
  }

  func testClineUsesShortestClinePassWindowFirst() {
    let usage = makeUsage(provider: .cline, metrics: [
      UsageMetric(id: "credit-balance", label: "Credit balance", usedDisplay: "$12.50"),
      UsageMetric(id: "monthly", label: "Monthly remaining", remainingPercent: 20),
      UsageMetric(id: "five_hour", label: "5-hour remaining", remainingPercent: 75),
      UsageMetric(id: "weekly", label: "Weekly remaining", remainingPercent: 40)
    ])
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five_hour", "weekly"])
    XCTAssertEqual(primaryLimitSlot(for: usage.metrics)?.kind, .monthly)
    XCTAssertFalse(chartsAsLongTermLimit(.session, accountKinds: [.session, .weekly, .monthly]))
  }

  func testClineCreditBalanceNeverInventsQuotaRings() {
    let usage = makeUsage(provider: .cline, metrics: [
      UsageMetric(id: "credit-balance", label: "Credit balance", usedDisplay: "$12.50")
    ])
    XCTAssertTrue(defaultRingMetrics(for: usage).isEmpty)
    XCTAssertNil(primaryLimitSlot(for: usage.metrics))
  }

  func testLongTermFilterDropsShortWindowsWhenALongerOneExists() {
    // Claude's 5-hour window goes, both weeklies stay.
    let claude: [QuotaWindowKind] = [.session, .weekly, .weekly]

    XCTAssertFalse(chartsAsLongTermLimit(.session, accountKinds: claude))
    XCTAssertTrue(chartsAsLongTermLimit(.weekly, accountKinds: claude))
  }

  func testLongTermFilterKeepsShortWindowsWithoutALongerOne() {
    // A session-only account would otherwise vanish from the chart entirely.
    let sessionOnly: [QuotaWindowKind] = [.session, .daily]

    XCTAssertTrue(chartsAsLongTermLimit(.session, accountKinds: sessionOnly))
    XCTAssertTrue(chartsAsLongTermLimit(.daily, accountKinds: sessionOnly))
  }

  func testLongTermFilterTreatsUnclassifiedWindowsAsLongTerm() {
    // Google's per-model quotas report no cadence; they anchor the account and
    // always chart themselves.
    let unclassified: [QuotaWindowKind] = [.session, .other]

    XCTAssertFalse(chartsAsLongTermLimit(.session, accountKinds: unclassified))
    XCTAssertTrue(chartsAsLongTermLimit(.other, accountKinds: unclassified))
  }

  func testLongTermFilterDropsZaiTokenWindowAlongsideItsMonthlyQuota() {
    // Z.ai's token window used to reach the chart as `.other` — unclassified,
    // therefore long-term — so it kept drawing after short-term limits were
    // hidden while Claude's and Kimi's equivalents dropped out.
    let zai = [
      QuotaWindowKind.classify(metricID: "tokens", label: "Token limit"),
      QuotaWindowKind.classify(metricID: "mcp", label: "MCP monthly quota")
    ]
    XCTAssertEqual(zai, [.session, .monthly])

    XCTAssertFalse(chartsAsLongTermLimit(zai[0], accountKinds: zai))
    XCTAssertTrue(chartsAsLongTermLimit(zai[1], accountKinds: zai))
  }

  private func metric(_ id: String) -> UsageMetric {
    UsageMetric(id: id, label: id, remainingPercent: 50)
  }

  private func makeUsage(provider: QuotaProvider, metrics: [UsageMetric]) -> ProviderUsage {
    ProviderUsage(
      accountID: "account",
      provider: provider,
      title: provider.displayName,
      metrics: metrics,
      fetchedAt: now
    )
  }
}
