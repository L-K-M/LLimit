import XCTest
@testable import QuotaCore
@testable import LLimitdCore

// PR #108 scripting/parser scenarios, plus the whole-snapshot check from #97.
final class ScriptCommandsTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func usage(_ id: String, provider: QuotaProvider = .anthropic, remaining: Int? = 40, age: TimeInterval = 300) -> ProviderUsage {
    ProviderUsage(accountID: id, provider: provider, title: id, metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: remaining)], fetchedAt: now.addingTimeInterval(-age))
  }
  private var snapshot: QuotaSnapshot {
    .init(generatedAt: now, providers: [usage("aa11"), usage("aa22", remaining: 8), usage("bb33", provider: .openAI, remaining: 70), usage("cc44", provider: .kimi, remaining: 99, age: 18_000)], failures: [
      ProviderFailure(accountID: "dd55", provider: .zai, kind: .auth, message: "expired", title: "Work")
    ])
  }
  private func check(_ args: [String], in snapshot: QuotaSnapshot? = nil) throws -> QuotaVerdict {
    QuotaCheck.check(try CheckOptions.parse(args), snapshot: snapshot ?? self.snapshot, now: now)
  }
  private func pick(_ args: [String]) throws -> QuotaVerdict { QuotaCheck.pick(try PickOptions.parse(args), snapshot: snapshot, now: now) }

  func testCheckExitStatusesBoundaryProviderBestAndAmbiguity() throws {
    XCTAssertEqual(try check(["aa11", "--min", "40"]).status, .ok)
    XCTAssertEqual(try check(["aa11", "--min", "41"]).status, .belowMinimum)
    XCTAssertEqual(try check(["cc44"]).status, .staleOrFailing)
    XCTAssertEqual(try check(["cc44", "--max-age", "6h"]).status, .ok)
    XCTAssertEqual(try check(["dd55"]).status, .staleOrFailing)
    XCTAssertEqual(try check(["anthropic", "--min", "20"]).candidate?.accountID, "aa11")
    XCTAssertEqual(try check(["aa2"]).candidate?.accountID, "aa22")
    XCTAssertEqual(try check(["AA2"]).candidate?.accountID, "aa22")
    XCTAssertEqual(try check(["aa"]).status, .usage)
    XCTAssertEqual(try check(["venice"]).status, .noData)
    XCTAssertEqual(QuotaCheck.check(try CheckOptions.parse([]), snapshot: nil, now: now).status, .noData)
    XCTAssertEqual([QuotaCheckStatus.ok, .belowMinimum, .staleOrFailing, .noData, .usage].map(\.rawValue), [0, 1, 2, 3, 64])
  }

  func testPickMostCurrentHeadroomAndProviderFilters() throws {
    XCTAssertEqual(try pick([]).candidate?.accountID, "bb33")
    XCTAssertEqual(try pick(["--provider", "anthropic"]).candidate?.accountID, "aa11")
    XCTAssertEqual(try pick(["--provider", "anthropic,kimi", "--max-age", "6h"]).candidate?.accountID, "cc44")
    XCTAssertEqual(try pick(["--provider", "anthropic", "--provider", "kimi", "--max-age", "6h"]).candidate?.accountID, "cc44")
    XCTAssertEqual(try pick(["--provider", "anthropic", "--min", "50"]).status, .belowMinimum)
    XCTAssertEqual(try pick(["--provider", "venice"]).status, .noData)
    XCTAssertEqual(try pick(["--provider", "anthropic", "--kind", "monthly"]).status, .noData)
  }

  func testWholeSnapshotCannotHideBadAccountsAndReportsAllIssues() throws {
    let verdict = try check(["--min", "10"])
    XCTAssertEqual(verdict.status, .staleOrFailing)
    for fragment in ["aa22", "cc44", "Work"] { XCTAssertTrue(verdict.message.contains(fragment)) }
    let healthy = QuotaSnapshot(generatedAt: now, providers: [usage("a")], failures: [])
    XCTAssertEqual(try check([], in: healthy).status, .ok)
    let low = QuotaSnapshot(generatedAt: now, providers: [usage("a", remaining: 0)], failures: [])
    XCTAssertEqual(try check([], in: low).status, .belowMinimum)
    let missing = QuotaSnapshot(generatedAt: now, providers: [usage("a"), usage("balance", provider: .venice, remaining: nil)], failures: [])
    XCTAssertEqual(try check([], in: missing).status, .noData)
    XCTAssertEqual(try check([], in: .init(generatedAt: now, providers: [], failures: [])).status, .noData)
  }

  func testSnapshotCadencePolicyIsUsedAndExplicitMaxAgeOverrides() throws {
    var slow = QuotaSnapshot(generatedAt: now, providers: [usage("old", age: 10_800)], failures: [], refreshIntervalMinutes: 180)
    XCTAssertEqual(try check(["old"], in: slow).status, .ok)
    XCTAssertEqual(try check(["old", "--max-age", "2h"], in: slow).status, .staleOrFailing)
    slow.refreshIntervalMinutes = nil
    XCTAssertEqual(try check(["old"], in: slow).status, .staleOrFailing)
  }

  func testProviderTargetsDoNotIncludeSameIDOfAnotherProvider() throws {
    let collision = QuotaSnapshot(generatedAt: now, providers: [usage("shared", remaining: 10), usage("shared", provider: .openAI, remaining: 99)], failures: [])
    XCTAssertEqual(try check(["anthropic"], in: collision).candidate?.usage.provider, .anthropic)
    let rendered = try StatusCommand.render(try StatusOptions.parse(["--account", "anthropic", "--format", "{provider}"]), snapshot: collision, now: now)
    XCTAssertEqual(rendered.text, "anthropic")
  }

  func testOptionsDurationsAndBoundedWatch() throws {
    let options = try PickOptions.parse(["--provider", "anthropic, openai", "--kind", "weekly", "--min", "10", "--max-age", "30m", "--format", "{provider}"])
    XCTAssertEqual(options.providers, [.anthropic, .openAI])
    XCTAssertEqual(options.criteria.maxAge, 1_800)
    XCTAssertNil(try PickOptions.parse([]).criteria.maxAge)
    for (text, seconds) in [("90", 90.0), ("90s", 90), ("15m", 900), ("2h", 7_200), ("1.5h", 5_400), ("1d", 86_400)] {
      XCTAssertEqual(CommandLineValues.duration(text), seconds)
    }
    for text in ["", "h", "0", "-1h", "nan", "infinity", "1e308h"] { XCTAssertNil(CommandLineValues.duration(text)) }
    XCTAssertEqual(try StatusOptions.parse(["--watch"]).watchInterval, 60)
    XCTAssertEqual(try StatusOptions.parse(["--watch=1d", "--json"]).watchInterval, 86_400)
    XCTAssertEqual(try StatusOptions.parse(["--watch", "2m"]).watchInterval, 120)
    for args in [["--json", "--compact"], ["--format", " "], ["--separator", "x"], ["--kind", "weekly"], ["--watch", "0.5"], ["--watch", "86401"], ["--watch=nan"], ["--bogus"]] {
      XCTAssertThrowsError(try StatusOptions.parse(args), "\(args)")
    }
    for args in [["--provider", ","], ["--provider", "anthropic,"], ["--format", " "], ["--min", "101"], ["--max-age", "0"], ["--kind", "yearly"]] {
      XCTAssertThrowsError(try PickOptions.parse(args), "\(args)")
    }
    XCTAssertThrowsError(try CheckOptions.parse(["a", "b"]))
    XCTAssertThrowsError(try CheckOptions.parse([""]))
  }

  func testStatusSelectionAndDefaultOutput() throws {
    XCTAssertEqual(try StatusCommand.render(.init(), snapshot: snapshot, now: now).text, StatusRenderer.humanReadable(snapshot: snapshot, now: now))
    let options = try StatusOptions.parse(["--format", "{id}", "--account", "venice", "--account", "bb33"])
    let rendered = try StatusCommand.render(options, snapshot: snapshot, now: now)
    XCTAssertEqual(rendered.text, "bb33")
    XCTAssertEqual(rendered.unmatchedTargets, ["venice"])
    let worst = try StatusCommand.render(try StatusOptions.parse(["--worst", "--format", "{id}"]), snapshot: snapshot, now: now)
    XCTAssertEqual(worst.text, "aa22")
    XCTAssertThrowsError(try StatusCommand.render(try StatusOptions.parse(["--account", "aa"]), snapshot: snapshot, now: now))
  }
}
