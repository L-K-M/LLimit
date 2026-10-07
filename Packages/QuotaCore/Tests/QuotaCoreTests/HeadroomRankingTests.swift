import XCTest
@testable import QuotaCore

final class HeadroomRankingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func usage(
    _ accountID: String,
    provider: QuotaProvider = .anthropic,
    title: String? = nil,
    metrics: [UsageMetric],
    age: TimeInterval = 300
  ) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: title ?? accountID,
      metrics: metrics,
      fetchedAt: now.addingTimeInterval(-age)
    )
  }

  private func metric(
    _ id: String,
    _ label: String,
    remaining: Int?,
    resetsIn: TimeInterval? = nil,
    unlimited: Bool = false
  ) -> UsageMetric {
    UsageMetric(
      id: id,
      label: label,
      remainingPercent: remaining,
      resetAt: resetsIn.map { now.addingTimeInterval($0) },
      isUnlimited: unlimited
    )
  }

  private func rank(
    _ providers: [ProviderUsage],
    failures: [ProviderFailure] = [],
    filter: HeadroomRanking.Filter = HeadroomRanking.Filter()
  ) -> HeadroomRanking.Ranking {
    HeadroomRanking.rank(
      snapshot: QuotaSnapshot(generatedAt: now, providers: providers, failures: failures),
      filter: filter,
      now: now
    )
  }

  func testHeadroomIsTheLowestBoundedMetric() {
    let ranking = rank([
      usage("deep", metrics: [
        metric("five_hour", "5-hour limit", remaining: 90),
        metric("seven_day", "7-day limit", remaining: 12)
      ]),
      usage("even", metrics: [
        metric("five_hour", "5-hour limit", remaining: 40),
        metric("seven_day", "7-day limit", remaining: 50)
      ])
    ])

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["even", "deep"])
    XCTAssertEqual(ranking.best?.headroom, .percent(40))
    XCTAssertEqual(ranking.worst?.headroom, .percent(12))
    XCTAssertEqual(ranking.worst?.limitingMetrics.map(\.id), ["seven_day"])
  }

  func testKindFilterRanksOnlyThatWindow() {
    let ranking = rank(
      [
        usage("session-heavy", metrics: [
          metric("five_hour", "5-hour limit", remaining: 5),
          metric("seven_day", "7-day limit", remaining: 80)
        ]),
        usage("week-heavy", metrics: [
          metric("five_hour", "5-hour limit", remaining: 95),
          metric("seven_day", "7-day limit", remaining: 30)
        ]),
        usage("no-weekly", metrics: [metric("five_hour", "5-hour limit", remaining: 100)])
      ],
      filter: HeadroomRanking.Filter(kind: .weekly)
    )

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["session-heavy", "week-heavy"])
    XCTAssertEqual(ranking.best?.headroom, .percent(80))
    XCTAssertEqual(ranking.exclusions.map(\.accountID), ["no-weekly"])
    XCTAssertEqual(ranking.exclusions.first?.reason, .noQuotaData)
  }

  func testTiesGoToTheSoonerReset() {
    let ranking = rank([
      usage("later", metrics: [metric("weekly", "Weekly", remaining: 50, resetsIn: 5 * 86_400)]),
      usage("unknown", metrics: [metric("weekly", "Weekly", remaining: 50)]),
      usage("sooner", metrics: [metric("weekly", "Weekly", remaining: 50, resetsIn: 86_400)])
    ])

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["sooner", "later", "unknown"])
  }

  func testTiedLimitingMetricsResetWhenTheLastOfThemResets() {
    // Headroom only grows once every metric at the minimum has reset.
    let both = usage("both", metrics: [
      metric("five_hour", "5-hour limit", remaining: 30, resetsIn: 3_600),
      metric("seven_day", "7-day limit", remaining: 30, resetsIn: 6 * 86_400)
    ])
    let weekly = usage("weekly", provider: .openAI, metrics: [
      metric("secondary", "7-day limit", remaining: 30, resetsIn: 3 * 86_400)
    ])

    let ranking = rank([both, weekly])

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["weekly", "both"])
    XCTAssertEqual(ranking.worst?.limitingMetrics.map(\.id), ["five_hour", "seven_day"])
    XCTAssertEqual(ranking.worst?.resetAt, now.addingTimeInterval(6 * 86_400))
  }

  func testFullTieFallsBackToADeterministicOrder() {
    let ranking = rank([
      usage("b", provider: .openAI, title: "Same", metrics: [metric("weekly", "Weekly", remaining: 70)]),
      usage("z", provider: .anthropic, title: "Zed", metrics: [metric("weekly", "Weekly", remaining: 70)]),
      usage("a", provider: .openAI, title: "Same", metrics: [metric("weekly", "Weekly", remaining: 70)]),
      usage("y", provider: .anthropic, title: "Alpha", metrics: [metric("weekly", "Weekly", remaining: 70)])
    ])

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["y", "z", "a", "b"])
  }

  func testUnlimitedRanksAboveEveryPercentageButNeverHidesABoundedLimit() {
    let ranking = rank([
      usage("full", metrics: [metric("weekly", "Weekly", remaining: 100)]),
      usage("unlimited", provider: .zhipu, metrics: [metric("plan", "Plan", remaining: nil, unlimited: true)]),
      usage("mixed", provider: .gitHubCopilot, metrics: [
        metric("chat", "Chat", remaining: nil, unlimited: true),
        metric("premium", "Premium", remaining: 20)
      ])
    ])

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["unlimited", "full", "mixed"])
    XCTAssertEqual(ranking.best?.headroom, .unlimited)
    XCTAssertEqual(ranking.worst?.headroom, .percent(20))
    XCTAssertTrue(HeadroomRanking.Headroom.percent(100) < .unlimited)
  }

  func testBalancesWithoutPercentagesAreNotQuotaData() {
    let ranking = rank([
      usage("credits", provider: .cline, metrics: [
        UsageMetric(id: "credits", label: "Credits", usedDisplay: "$4.25")
      ]),
      usage("quota", metrics: [metric("weekly", "Weekly", remaining: 3)])
    ])

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["quota"])
    XCTAssertEqual(ranking.exclusions.map(\.reason), [.noQuotaData])
  }

  func testStaleAndFailingAccountsAreExcludedForCurrentUse() {
    let ranking = rank(
      [
        usage("fresh", metrics: [metric("weekly", "Weekly", remaining: 10)]),
        usage("old", metrics: [metric("weekly", "Weekly", remaining: 90)], age: 3 * 3_600),
        // A failing account keeps its last usage in the snapshot (mergingStaleUsage).
        usage("carried", metrics: [metric("weekly", "Weekly", remaining: 95)])
      ],
      failures: [
        ProviderFailure(accountID: "carried", provider: .anthropic, kind: .auth, message: "401"),
        ProviderFailure(accountID: "never", provider: .openAI, kind: .network, message: "offline")
      ]
    )

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["fresh"])
    XCTAssertEqual(Set(ranking.exclusions.map(\.accountID)).count, ranking.exclusions.count, "one exclusion per account")
    XCTAssertEqual(
      Dictionary(ranking.exclusions.map { ($0.accountID, $0.reason) }, uniquingKeysWith: { first, _ in first }),
      [
        "old": .stale(fetchedAt: now.addingTimeInterval(-3 * 3_600)),
        "carried": .failing(.auth),
        "never": .failing(.network)
      ]
    )
    XCTAssertEqual(ranking.exclusions.first(where: { $0.accountID == "never" })?.name, "OpenAI")
  }

  func testMaxAgeIsConfigurable() {
    let accounts = [usage("ten-minutes", metrics: [metric("weekly", "Weekly", remaining: 50)], age: 600)]

    XCTAssertEqual(rank(accounts, filter: HeadroomRanking.Filter(eligibility: .current(maxAge: 900))).candidates.count, 1)
    XCTAssertEqual(rank(accounts, filter: HeadroomRanking.Filter(eligibility: .current(maxAge: 300))).candidates.count, 0)
    // Only data strictly older than maxAge is stale, like the JSON contract's `stale` flag.
    XCTAssertEqual(rank(accounts, filter: HeadroomRanking.Filter(eligibility: .current(maxAge: 600))).candidates.count, 1)
  }

  func testFailuresBelongToTheAccountWithTheSameProviderAndID() {
    let ranking = rank(
      [
        usage("work", provider: .anthropic, metrics: [metric("weekly", "Weekly", remaining: 90)]),
        usage("work", provider: .openAI, metrics: [metric("secondary", "7-day limit", remaining: 40)])
      ],
      failures: [
        ProviderFailure(accountID: "work", provider: .anthropic, kind: .auth, message: "401"),
        ProviderFailure(accountID: "work", provider: .kimi, kind: .network, message: "offline")
      ]
    )

    XCTAssertEqual(ranking.candidates.map(\.usage.provider), [.openAI])
    XCTAssertEqual(ranking.exclusions.map(\.provider), [.anthropic, .kimi])
    XCTAssertEqual(ranking.exclusions.map(\.reason), [.failing(.auth), .failing(.network)])
  }

  func testAccountThatFailedRepeatedlyIsExcludedOnce() {
    let ranking = rank(
      [],
      failures: [
        ProviderFailure(accountID: "z", provider: .zai, kind: .auth, message: "401"),
        ProviderFailure(accountID: "z", provider: .zai, kind: .network, message: "offline"),
        ProviderFailure(accountID: "z", provider: .kimi, kind: .auth, message: "401")
      ]
    )

    XCTAssertEqual(ranking.exclusions.map(\.provider), [.zai, .kimi])
    XCTAssertEqual(ranking.exclusions.map(\.reason), [.failing(.auth), .failing(.auth)])
  }

  func testLegacyProviderKeyedEntriesStillPairUp() throws {
    // Snapshots from before multi-account support carry no accountID; both
    // sides decode it as the provider's raw value.
    let legacy = Data("""
    {"version": 1, "generatedAt": "2023-11-14T22:13:20Z",
     "providers": [{"provider": "anthropic", "title": "Claude", "metrics": [
       {"id": "seven_day", "label": "7-day limit", "remainingPercent": 50, "isUnlimited": false}],
       "fetchedAt": "2023-11-14T22:13:20Z"}],
     "failures": [{"provider": "anthropic", "kind": "auth", "message": "401"}]}
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(QuotaSnapshot.self, from: legacy)

    let ranking = HeadroomRanking.rank(snapshot: snapshot, filter: HeadroomRanking.Filter(), now: now)

    XCTAssertTrue(ranking.candidates.isEmpty)
    XCTAssertEqual(ranking.exclusions.map(\.accountID), ["anthropic"])
    XCTAssertEqual(ranking.exclusions.map(\.reason), [.failing(.auth)])
  }

  func testEmptySnapshotRanksNothing() {
    let ranking = rank([])

    XCTAssertTrue(ranking.candidates.isEmpty)
    XCTAssertTrue(ranking.exclusions.isEmpty)
    XCTAssertNil(ranking.best)
    XCTAssertNil(ranking.worst)
  }

  func testKindFilterAppliesToUnlimitedMetricsToo() {
    let zhipu = [usage("z", provider: .zhipu, metrics: [metric("plan", "Monthly plan", remaining: nil, unlimited: true)])]

    XCTAssertEqual(rank(zhipu, filter: HeadroomRanking.Filter(kind: .monthly)).best?.headroom, .unlimited)
    XCTAssertEqual(rank(zhipu, filter: HeadroomRanking.Filter(kind: .weekly)).exclusions.map(\.reason), [.noQuotaData])
  }

  func testAnyReportedRanksStaleAndFailingUsage() {
    let ranking = rank(
      [
        usage("fresh", metrics: [metric("weekly", "Weekly", remaining: 60)]),
        usage("old", metrics: [metric("weekly", "Weekly", remaining: 4)], age: 10 * 3_600),
        usage("carried", metrics: [metric("weekly", "Weekly", remaining: 30)])
      ],
      failures: [
        ProviderFailure(accountID: "carried", provider: .anthropic, kind: .auth, message: "401"),
        ProviderFailure(accountID: "never", provider: .openAI, kind: .network, message: "offline")
      ],
      filter: HeadroomRanking.Filter(eligibility: .anyReported)
    )

    XCTAssertEqual(ranking.candidates.map(\.accountID), ["fresh", "carried", "old"])
    XCTAssertEqual(ranking.exclusions.map(\.accountID), ["never"])
  }

  func testProviderAndAccountFilters() {
    let accounts = [
      usage("claude", metrics: [metric("weekly", "Weekly", remaining: 50)]),
      usage("codex", provider: .openAI, metrics: [metric("secondary", "7-day limit", remaining: 60)]),
      usage("kimi", provider: .kimi, metrics: [metric("plan-weekly", "Weekly", remaining: 99)])
    ]
    let failures = [ProviderFailure(accountID: "venice", provider: .venice, kind: .auth, message: "403")]

    let byProvider = rank(accounts, failures: failures, filter: HeadroomRanking.Filter(providers: [.anthropic, .openAI]))
    XCTAssertEqual(byProvider.candidates.map(\.accountID), ["codex", "claude"])
    XCTAssertTrue(byProvider.exclusions.isEmpty)

    let byAccount = rank(accounts, failures: failures, filter: HeadroomRanking.Filter(accountIDs: ["claude", "venice"]))
    XCTAssertEqual(byAccount.candidates.map(\.accountID), ["claude"])
    XCTAssertEqual(byAccount.exclusions.map(\.accountID), ["venice"])

    // An empty set selects nothing; only nil means "any".
    let none = rank(accounts, filter: HeadroomRanking.Filter(accountIDs: []))
    XCTAssertTrue(none.candidates.isEmpty)
  }

  func testEstimatedHeadroomIsFlagged() throws {
    let venice = usage("venice", provider: .venice, metrics: [
      UsageMetric(id: "daily-diem", label: "Daily DIEM", remainingPercent: 40, remainingAmount: 4, estimatedTotal: 10)
    ])

    let candidate = try XCTUnwrap(rank([venice]).best)

    XCTAssertTrue(candidate.isEstimated)
    XCTAssertEqual(rank([usage("plain", metrics: [metric("weekly", "Weekly", remaining: 40)])]).best?.isEstimated, false)
  }
}
