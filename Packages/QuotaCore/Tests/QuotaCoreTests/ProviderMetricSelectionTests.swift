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
