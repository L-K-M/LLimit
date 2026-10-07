import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class ScriptCommandsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func usage(
    _ accountID: String,
    provider: QuotaProvider = .anthropic,
    title: String? = nil,
    remaining: Int?,
    age: TimeInterval = 300
  ) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: title ?? accountID,
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining, usedDisplay: remaining == nil ? "$5" : nil)],
      fetchedAt: now.addingTimeInterval(-age)
    )
  }

  /// Two Claude accounts, one stale Kimi, one OpenAI, one failing Z.ai.
  private var snapshot: QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now,
      providers: [
        usage("aa11", title: "Claude Work", remaining: 40),
        usage("aa22", title: "Claude Home", remaining: 8),
        usage("bb33", provider: .openAI, title: "OpenAI", remaining: 70),
        usage("cc44", provider: .kimi, title: "Kimi", remaining: 99, age: 5 * 3_600)
      ],
      failures: [ProviderFailure(accountID: "dd55", provider: .zai, kind: .auth, message: "401")]
    )
  }

  // MARK: - check

  private func check(_ args: [String], snapshot: QuotaSnapshot? = nil) throws -> QuotaVerdict {
    QuotaCheck.check(try CheckOptions.parse(args), snapshot: snapshot ?? self.snapshot, now: now)
  }

  func testCheckExitStatuses() throws {
    XCTAssertEqual(try check(["aa11"]).status, .ok)
    XCTAssertEqual(try check(["aa11", "--min", "40"]).status, .ok)
    XCTAssertEqual(try check(["aa11", "--min", "41"]).status, .belowMinimum)
    XCTAssertEqual(try check(["aa22"]).status, .ok)
    XCTAssertEqual(try check(["cc44"]).status, .staleOrFailing)
    XCTAssertEqual(try check(["cc44", "--max-age", "6h"]).status, .ok)
    XCTAssertEqual(try check(["dd55"]).status, .staleOrFailing)
    XCTAssertEqual(try check(["zz"]).status, .noData)
    XCTAssertEqual(try check(["venice"]).status, .noData)
    XCTAssertEqual(QuotaCheck.check(try CheckOptions.parse(["anthropic"]), snapshot: nil, now: now).status, .noData)
    XCTAssertEqual(QuotaCheck.check(try CheckOptions.parse(["aa11"]), snapshot: nil, now: now).status, .noData)

    XCTAssertEqual(QuotaCheckStatus.ok.rawValue, 0)
    XCTAssertEqual(QuotaCheckStatus.belowMinimum.rawValue, 1)
    XCTAssertEqual(QuotaCheckStatus.staleOrFailing.rawValue, 2)
    XCTAssertEqual(QuotaCheckStatus.noData.rawValue, 3)
    XCTAssertEqual(QuotaCheckStatus.usage.rawValue, 64)
  }

  func testCheckingAProviderUsesItsBestAccount() throws {
    let verdict = try check(["anthropic", "--min", "20"])

    XCTAssertEqual(verdict.status, .ok)
    XCTAssertEqual(verdict.candidate?.accountID, "aa11")
    XCTAssertEqual(verdict.message, "ok: Claude Work (anthropic) has 40% left (Weekly)")
    XCTAssertEqual(try check(["anthropic", "--min", "50"]).message, "below minimum: Claude Work (anthropic) has 40% left (Weekly); minimum is 50%")
  }

  func testCheckTargetsResolveLikeTheAccountsShorthand() throws {
    XCTAssertEqual(try check(["aa2"]).candidate?.accountID, "aa22")

    let ambiguous = try check(["aa"])
    XCTAssertEqual(ambiguous.status, .usage)
    XCTAssertEqual(ambiguous.message, "\"aa\" matches several accounts: aa11, aa22")
  }

  func testStaleOrFailingBeatsNoDataAndNamesTheCause() throws {
    let mixed = QuotaSnapshot(
      generatedAt: now,
      providers: [
        usage("balance", provider: .venice, remaining: nil),
        usage("old", provider: .venice, title: "Venice Old", remaining: 50, age: 3 * 3_600)
      ],
      failures: []
    )

    let verdict = try check(["venice"], snapshot: mixed)

    XCTAssertEqual(verdict.status, .staleOrFailing)
    XCTAssertEqual(verdict.message, "stale or failing: Venice Old (venice) was last updated 3 h ago")
    XCTAssertEqual(try check(["balance"], snapshot: mixed).status, .noData)
    XCTAssertEqual(try check(["dd55"]).message, "stale or failing: Z.ai (zai) failed to refresh (auth)")
  }

  func testUnlimitedQuotaPassesAnyMinimum() throws {
    let zhipu = QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          accountID: "z",
          provider: .zhipu,
          title: "Zhipu",
          metrics: [UsageMetric(id: "plan", label: "Plan", isUnlimited: true)],
          fetchedAt: now
        )
      ],
      failures: []
    )

    let verdict = try check(["zhipu", "--min", "100"], snapshot: zhipu)

    XCTAssertEqual(verdict.status, .ok)
    XCTAssertEqual(verdict.message, "ok: Zhipu (zhipu) has unlimited quota (Plan)")
  }

  // MARK: - pick

  private func pick(_ args: [String]) throws -> QuotaVerdict {
    QuotaCheck.pick(try PickOptions.parse(args), snapshot: snapshot, now: now)
  }

  func testPickChoosesTheMostHeadroomAmongCurrentAccounts() throws {
    // Kimi has more left but its data is five hours old.
    XCTAssertEqual(try pick([]).candidate?.accountID, "bb33")
    XCTAssertEqual(try pick(["--provider", "anthropic"]).candidate?.accountID, "aa11")
    XCTAssertEqual(try pick(["--provider", "anthropic,kimi", "--max-age", "6h"]).candidate?.accountID, "cc44")
    XCTAssertEqual(try pick(["--provider", "anthropic", "--provider", "kimi", "--max-age", "6h"]).candidate?.accountID, "cc44")
    XCTAssertEqual(try pick(["--provider", "anthropic", "--min", "50"]).status, .belowMinimum)
    XCTAssertEqual(try pick(["--provider", "kimi"]).status, .staleOrFailing)
    XCTAssertEqual(try pick(["--provider", "cline"]).status, .noData)
    XCTAssertEqual(try pick(["--provider", "anthropic,openai", "--kind", "monthly"]).status, .noData)
    // A failing account might have the window, so refreshing may help.
    XCTAssertEqual(try pick(["--kind", "monthly"]).status, .staleOrFailing)
  }

  func testPickOptions() throws {
    let options = try PickOptions.parse(["--provider", "anthropic, openai", "--kind", "weekly", "--min", "10", "--max-age", "30m", "--format", "{provider}"])

    XCTAssertEqual(options.providers, [.anthropic, .openAI])
    XCTAssertEqual(options.criteria.kind, .weekly)
    XCTAssertEqual(options.criteria.minimum, 10)
    XCTAssertEqual(options.criteria.maxAge, 1_800)
    XCTAssertEqual(options.template, "{provider}")

    let defaults = try PickOptions.parse([])
    XCTAssertNil(defaults.providers)
    XCTAssertEqual(defaults.criteria.minimum, 1)
    XCTAssertEqual(defaults.criteria.maxAge, 7_200)
    XCTAssertEqual(defaults.template, "{id}\t{name}")

    for bad in [["--provider", "claude"], ["--provider", ","], ["--kind", "yearly"], ["--min", "101"], ["--min", "x"], ["--max-age", "0"], ["--max-age"], ["extra"]] {
      XCTAssertThrowsError(try PickOptions.parse(bad), "\(bad)")
    }
  }

  func testCheckOptions() throws {
    let options = try CheckOptions.parse(["--min", "15", "anthropic", "--max-age", "45m", "--kind", "session"])

    XCTAssertEqual(options.target, "anthropic")
    XCTAssertEqual(options.criteria.minimum, 15)
    XCTAssertEqual(options.criteria.maxAge, 2_700)
    XCTAssertEqual(options.criteria.kind, .session)

    for bad in [[], ["a", "b"], ["a", "--bogus"], ["a", "--min"]] {
      XCTAssertThrowsError(try CheckOptions.parse(bad), "\(bad)")
    }
  }

  func testDurations() {
    XCTAssertEqual(CommandLineValues.duration("90"), 90)
    XCTAssertEqual(CommandLineValues.duration("90s"), 90)
    XCTAssertEqual(CommandLineValues.duration("15m"), 900)
    XCTAssertEqual(CommandLineValues.duration("2h"), 7_200)
    XCTAssertEqual(CommandLineValues.duration("1.5h"), 5_400)
    XCTAssertEqual(CommandLineValues.duration("1d"), 86_400)
    for bad in ["", "h", "-1h", "0", "2w", "nan", "two"] {
      XCTAssertNil(CommandLineValues.duration(bad), bad)
    }
  }

  // MARK: - status

  private func status(_ args: [String], snapshot: QuotaSnapshot? = nil) throws -> StatusCommand.Rendering {
    try StatusCommand.render(try StatusOptions.parse(args), snapshot: snapshot ?? self.snapshot, now: now)
  }

  func testDefaultAndJSONOutputAreTheRendererOutputUnchanged() throws {
    XCTAssertEqual(try status([]).text, StatusRenderer.humanReadable(snapshot: snapshot, now: now))
    XCTAssertEqual(try status(["--json"]).text, StatusRenderer.waybarJSON(snapshot: snapshot, now: now))
    XCTAssertEqual(
      try StatusCommand.render(StatusOptions(), snapshot: nil, now: now).text,
      StatusRenderer.humanReadable(snapshot: nil, now: now)
    )
  }

  func testAccountSelection() throws {
    XCTAssertEqual(try status(["--format", "{id}", "--account", "anthropic"]).text, "aa22 · aa11")
    XCTAssertEqual(try status(["--format", "{id}", "--account", "bb", "--account", "dd55"]).text, "bb33 · dd55")

    let unmatched = try status(["--format", "{id}", "--account", "nope"])
    XCTAssertEqual(unmatched.text, "")
    XCTAssertEqual(unmatched.unmatchedTargets, ["nope"])

    XCTAssertThrowsError(try status(["--account", "aa"]))
  }

  func testWorstShowsTheLeastHeadroomIncludingStaleAccounts() throws {
    let stale = QuotaSnapshot(
      generatedAt: now,
      providers: [usage("fresh", remaining: 50), usage("old", remaining: 5, age: 10 * 3_600)],
      failures: []
    )

    XCTAssertEqual(try status(["--worst", "--format", "{id} {remaining} {stale}"], snapshot: stale).text, "old 5% stale")
    XCTAssertEqual(try status(["--worst", "--format", "{name}"]).text, "Claude Home")
    XCTAssertEqual(try status(["--worst", "--format", "{name}", "--account", "openai"]).text, "OpenAI")

    let human = try status(["--worst"]).text
    XCTAssertTrue(human.contains("Claude Home"))
    XCTAssertFalse(human.contains("OpenAI"))
    XCTAssertFalse(human.contains("Z.ai"))
  }

  func testStatusOptions() throws {
    XCTAssertEqual(try StatusOptions.parse([]), StatusOptions())
    XCTAssertEqual(try StatusOptions.parse(["--json"]).output, .json)

    let options = try StatusOptions.parse(["--format", "{name}", "--separator", " | ", "--kind", "weekly", "--watch"])
    XCTAssertEqual(options.output, .template("{name}"))
    XCTAssertEqual(options.separator, " | ")
    XCTAssertEqual(options.kind, .weekly)
    XCTAssertEqual(options.watchInterval, StatusOptions.defaultWatchInterval)

    XCTAssertEqual(try StatusOptions.parse(["--watch", "5", "--json"]).watchInterval, 5)
    XCTAssertEqual(try StatusOptions.parse(["--watch", "2m"]).watchInterval, 120)
    XCTAssertEqual(try StatusOptions.parse(["--worst", "--kind", "daily"]).selection, .worst)

    for bad in [["--json", "--format", "x"], ["--separator", "x"], ["--kind", "weekly"], ["--watch", "0.5"], ["--watch", "soon"], ["--format"], ["--bogus"], ["stray"]] {
      XCTAssertThrowsError(try StatusOptions.parse(bad), "\(bad)")
    }
  }
}
