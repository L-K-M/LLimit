import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class StatusTemplateTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func usage(
    _ accountID: String,
    provider: QuotaProvider = .anthropic,
    title: String,
    metrics: [UsageMetric],
    warning: String? = nil,
    age: TimeInterval = 300
  ) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: title,
      metrics: metrics,
      warning: warning,
      fetchedAt: now.addingTimeInterval(-age)
    )
  }

  private func render(
    _ template: String,
    _ providers: [ProviderUsage],
    failures: [ProviderFailure] = [],
    kind: QuotaWindowKind? = nil,
    separator: String = StatusTemplate.defaultSeparator
  ) -> String {
    StatusTemplate.render(
      template,
      snapshot: QuotaSnapshot(generatedAt: now, providers: providers, failures: failures),
      kind: kind,
      separator: separator,
      now: now
    )
  }

  private var claude: ProviderUsage {
    usage("claude-id", title: "Claude", metrics: [
      UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 70, resetAt: now.addingTimeInterval(3_600)),
      UsageMetric(id: "seven_day", label: "7-day limit", remainingPercent: 30, resetAt: now.addingTimeInterval(2 * 86_400 + 3 * 3_600))
    ])
  }

  func testEveryPlaceholderExpands() {
    let line = render(
      "{id}|{name}|{provider}|{remaining}|{metric}|{kind}|{reset}|{class}|{age}|{stale}",
      [claude]
    )

    XCTAssertEqual(line, "claude-id|Claude|anthropic|30%|7-day limit|weekly|2d 3h|warning|5 min ago|")
  }

  func testKindSelectsTheWindowBehindRemaining() {
    XCTAssertEqual(render("{remaining} {kind} {reset}", [claude], kind: .session), "70% session 1h")
    XCTAssertEqual(render("{remaining} {metric}", [claude], kind: .monthly), "n/a ")
  }

  func testUnknownPlaceholdersAndStrayBracesStayLiteral() {
    XCTAssertEqual(render("{nope} {name} {{name}} {name", [claude]), "{nope} Claude {Claude} {name")
    XCTAssertEqual(render("}{}{", [claude]), "}{}{")
  }

  func testAccountsJoinInStatusOrderWithFailedOnlyAccountsLast() {
    let providers = [
      usage("o", provider: .openAI, title: "OpenAI", metrics: [UsageMetric(id: "primary", label: "5-hour limit", remainingPercent: 90)]),
      usage("b", title: "Claude B", metrics: [UsageMetric(id: "seven_day", label: "7-day limit", remainingPercent: 10)]),
      usage("a", title: "Claude A", metrics: [UsageMetric(id: "seven_day", label: "7-day limit", remainingPercent: 50)])
    ]
    let failures = [ProviderFailure(accountID: "z", provider: .zai, kind: .auth, message: "401")]

    XCTAssertEqual(
      render("{name} {remaining} {class}", providers, failures: failures, separator: "\n"),
      "Claude A 50% ok\nClaude B 10% critical\nOpenAI 90% ok\nZ.ai n/a error"
    )
  }

  func testEmptyAndMissingSnapshotsRenderNothing() {
    XCTAssertEqual(render("{name} {remaining}", []), "")
    XCTAssertEqual(StatusTemplate.render("{name}", snapshot: nil, kind: nil, separator: " ", now: now), "")
  }

  func testEstimatesKeepTheApproximatePrefix() {
    let venice = usage("v", provider: .venice, title: "Venice", metrics: [
      UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingPercent: 64, remainingAmount: 6.4, estimatedTotal: 10)
    ])

    XCTAssertEqual(render("{remaining}", [venice]), "≈64%")
  }

  func testUnlimitedBalancesAndFailuresAreExplicit() {
    let unlimited = usage("u", provider: .zhipu, title: "Zhipu", metrics: [UsageMetric(id: "plan", label: "Plan", isUnlimited: true)])
    let credits = usage("c", provider: .cline, title: "Cline", metrics: [UsageMetric(id: "credits", label: "Credits", usedDisplay: "$4.25")])
    // A failing account keeps its carried usage, but its class says the refresh failed.
    let carried = usage("f", title: "Claude", metrics: [UsageMetric(id: "seven_day", label: "7-day limit", remainingPercent: 80)])

    XCTAssertEqual(
      render(
        "{name}:{remaining}:{class}",
        [unlimited, credits, carried],
        failures: [ProviderFailure(accountID: "f", provider: .anthropic, kind: .network, message: "offline")],
        separator: " "
      ),
      "Claude:80%:error Cline:n/a:empty Zhipu:unlimited:ok"
    )
  }

  func testClassUsesTheJSONContractCutoffs() {
    let accounts = [14, 15, 39, 40].map { (percent: Int) -> ProviderUsage in
      usage("p\(percent)", title: "P\(percent)", metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: percent)])
    }

    XCTAssertEqual(render("{name} {class}", accounts, separator: ", "), "P14 critical, P15 warning, P39 warning, P40 ok")
  }

  func testAFailureMarksOnlyTheAccountWithTheSameProviderAndID() {
    let claude = usage("work", title: "Claude", metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 90)])
    let openAI = usage("work", provider: .openAI, title: "OpenAI", metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 90)])
    let failures = [ProviderFailure(accountID: "work", provider: .kimi, kind: .auth, message: "401")]

    XCTAssertEqual(
      render("{name} {class}", [claude, openAI], failures: failures, separator: "; "),
      "Claude ok; OpenAI ok; Kimi error"
    )
  }

  func testStaleDataAndProviderWarningsAreMarked() {
    let old = usage("old", title: "Old", metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 90)], age: 3 * 3_600)
    let limited = usage(
      "rl",
      provider: .openAI,
      title: "Limited",
      metrics: [UsageMetric(id: "primary", label: "5-hour limit", remainingPercent: 90)],
      warning: "Rate limit reached"
    )

    XCTAssertEqual(render("{name} {class} {stale} {age}", [old, limited], separator: "; "), "Old ok stale 3 h ago; Limited warning  5 min ago")
  }

  func testValuesNeverBreakTheLineOrTabSeparatedColumns() {
    let odd = usage("odd", title: "Work\nTeam\tA", metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 50)])

    XCTAssertEqual(render(StatusTemplate.pickDefault, [odd]), "odd\tWork Team A")
  }

  func testSingleAccountRender() {
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [claude, usage("x", title: "Other", metrics: [])], failures: [])

    XCTAssertEqual(
      StatusTemplate.render("{id} {name}", accountID: "claude-id", in: snapshot, kind: nil, now: now),
      "claude-id Claude"
    )
  }
}
