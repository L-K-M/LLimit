import XCTest
@testable import QuotaCore

final class QuotaDisplayTextTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testRelativeAgeBoundaries() {
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(-59), now: now), "just now")
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(-60), now: now), "1 min ago")
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(-59 * 60), now: now), "59 min ago")
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(-60 * 60), now: now), "1 h ago")
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(-47 * 3_600), now: now), "47 h ago")
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(-48 * 3_600), now: now), "2 d ago")
  }

  func testRelativeAgeTreatsFutureDatesAsJustNow() {
    // The dashboard clock ticks once a minute, so a refresh that lands between
    // ticks has a timestamp after the displayed "now".
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(45), now: now), "just now")
    XCTAssertEqual(QuotaDisplayText.relativeAge(now.addingTimeInterval(3_600), now: now), "just now")
  }

  func testOutOfRangeAgeDoesNotTrap() {
    XCTAssertEqual(QuotaDisplayText.relativeAge(Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude), now: now),
                   "unknown age")
  }

  func testCountPhraseUsesSingularOnlyForOne() {
    XCTAssertEqual(QuotaDisplayText.countPhrase(0, singular: "account", plural: "accounts"), "0 accounts")
    XCTAssertEqual(QuotaDisplayText.countPhrase(1, singular: "account", plural: "accounts"), "1 account")
    XCTAssertEqual(QuotaDisplayText.countPhrase(2, singular: "METRIC", plural: "METRICS"), "2 METRICS")
  }

  func testRenamedZaiAccountShowsTheProviderOnce() {
    // The Z.ai client reports "Z.ai" as its subtitle.
    let parts = QuotaDisplayText.accountDetailParts(providerName: "Z.ai", accountName: "Team GLM", subtitle: "Z.ai")

    XCTAssertEqual(parts, ["Z.ai"])
  }

  func testDefaultNamedOpenCodeGoAccountHasNoRepeatedName() {
    let parts = QuotaDisplayText.accountDetailParts(
      providerName: "OpenCode Go",
      accountName: "OpenCode Go",
      subtitle: "OpenCode Go"
    )

    XCTAssertEqual(parts, [])
  }

  func testCopilotHandleIsKept() {
    let parts = QuotaDisplayText.accountDetailParts(
      providerName: "GitHub Copilot",
      accountName: "Work",
      subtitle: "@octocat (individual_pro)"
    )

    XCTAssertEqual(parts, ["GitHub Copilot", "@octocat (individual_pro)"])
  }

  func testMissingOrBlankSubtitleLeavesTheProvider() {
    XCTAssertEqual(
      QuotaDisplayText.accountDetailParts(providerName: "OpenAI", accountName: "GPT Lukas", subtitle: nil),
      ["OpenAI"]
    )
    XCTAssertEqual(
      QuotaDisplayText.accountDetailParts(providerName: "OpenAI", accountName: "GPT Lukas", subtitle: "  "),
      ["OpenAI"]
    )
  }

  func testDefaultNamedClaudeAccountDropsTheProvider() {
    let parts = QuotaDisplayText.accountDetailParts(providerName: "Claude", accountName: "Claude", subtitle: nil)

    XCTAssertEqual(parts, [])
  }

  func testDuplicatesMatchIgnoringCaseAndSurroundingWhitespace() {
    let parts = QuotaDisplayText.accountDetailParts(
      providerName: "Z.ai",
      accountName: " z.AI ",
      subtitle: "Coding Plan "
    )

    XCTAssertEqual(parts, ["Coding Plan"])
  }

  func testSubtitleEqualToTheAccountNameIsDropped() {
    let parts = QuotaDisplayText.accountDetailParts(
      providerName: "Google Antigravity",
      accountName: "me@example.com",
      subtitle: "ME@example.com"
    )

    XCTAssertEqual(parts, ["Google Antigravity"])
  }
}
