import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MonthlyQuotaCycleTests: XCTestCase {

  // Independent ISO 8601 helper — not dependent on production parseQuotaResetDate.
  private func fixtureDate(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
      XCTFail("Invalid fixture date: \(iso)")
      return .distantPast
    }
    return date
  }

  // -- Anchor parsing delegates to parseQuotaResetDate --

  func testAnchorParsing() throws {
    // Date-only → midnight UTC.
    let mid = fixtureDate("2026-10-19T00:00:00Z")
    XCTAssertEqual(try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-10-19")).anchor, mid)

    // ISO with explicit Z.
    let z = fixtureDate("2026-10-19T20:14:00Z")
    XCTAssertEqual(try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-10-19T20:14:00Z")).anchor, z)

    // ISO with explicit offset — canonicalised to UTC.
    let utc10 = fixtureDate("2026-10-20T10:00:00Z")
    XCTAssertEqual(try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-10-20T12:00:00+02:00")).anchor, utc10)

    // Fractional seconds preserved.
    let frac = fixtureDate("2026-01-31T22:14:00.125Z")
    XCTAssertEqual(try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-01-31T22:14:00.125Z")).anchor, frac)

    // Zone-less timestamp rejected.
    XCTAssertNil(MonthlyQuotaCycle(anchor: "2026-10-19T20:14:00"))

    // Invalid dates rejected.
    XCTAssertNil(MonthlyQuotaCycle(anchor: "2026-02-30"))
    XCTAssertNil(MonthlyQuotaCycle(anchor: "2026-13-01"))
    XCTAssertNil(MonthlyQuotaCycle(anchor: "not-a-date"))
  }

  // -- resetAt core behaviour --

  func testResetAtBasicMonthlyAdvance() throws {
    // anchor 2026-10-19T20:14:00Z, now 2026-10-20T07:45:00Z → 2026-11-19T20:14:00Z
    let now = fixtureDate("2026-10-20T07:45:00Z")
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-10-19T20:14:00Z"))
    let expected = fixtureDate("2026-11-19T20:14:00Z")
    XCTAssertEqual(cycle.resetAt(after: now), expected)
  }

  func testResetAtExactAnchorAndNext() throws {
    // Exact anchor → next month same clock.
    let anchor = fixtureDate("2026-10-19T20:14:00Z")
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-10-19T20:14:00Z"))
    let next = fixtureDate("2026-11-19T20:14:00Z")
    XCTAssertEqual(cycle.resetAt(after: anchor), next)

    // Exact next → month after.
    let following = fixtureDate("2026-12-19T20:14:00Z")
    XCTAssertEqual(cycle.resetAt(after: next), following)
  }

  func testResetAtEndOfMonthRestoresDay31() throws {
    // anchor 2026-01-31T22:14:00.125Z
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-01-31T22:14:00.125Z"))

    // now Feb 1 → Feb 28 (Jan 31 doesn't exist in Feb).
    let feb1 = fixtureDate("2026-02-01T00:00:00Z")
    let feb28 = fixtureDate("2026-02-28T22:14:00.125Z")
    XCTAssertEqual(cycle.resetAt(after: feb1), feb28)

    // now Feb 28 at 22:14:.125 → Mar 31 (restore day 31).
    XCTAssertEqual(cycle.resetAt(after: feb28), fixtureDate("2026-03-31T22:14:00.125Z"))

    // now Mar 31 exact → Apr 30 (clamp to April's last day).
    let mar31 = fixtureDate("2026-03-31T22:14:00.125Z")
    XCTAssertEqual(cycle.resetAt(after: mar31), fixtureDate("2026-04-30T22:14:00.125Z"))
  }

  func testResetAtLeapYear() throws {
    // 2024 is a leap year.
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2024-01-31"))

    // now Feb 1 → Feb 29 (leap year).
    let feb1 = fixtureDate("2024-02-01T00:00:00Z")
    let feb29 = fixtureDate("2024-02-29T00:00:00Z")
    XCTAssertEqual(cycle.resetAt(after: feb1), feb29)

    // now Feb 29 exact → Mar 31.
    XCTAssertEqual(cycle.resetAt(after: feb29), fixtureDate("2024-03-31T00:00:00Z"))
  }

  func testResetAtLeapYearAnchorToNonLeap() throws {
    // anchor 2024-02-29T12:00Z, now 2025-02-01 → 2025-02-28T12:00Z.
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2024-02-29T12:00:00Z"))
    let feb1 = fixtureDate("2025-02-01T00:00:00Z")
    XCTAssertEqual(cycle.resetAt(after: feb1), fixtureDate("2025-02-28T12:00:00Z"))

    // Restore the original anchor day, the 29th, after February clamping.
    let feb28 = fixtureDate("2025-02-28T12:00:00Z")
    XCTAssertEqual(cycle.resetAt(after: feb28), fixtureDate("2025-03-29T12:00:00Z"))
  }

  func testResetAtLongElapsedNoDrift() throws {
    // anchor 2000-01-31, now 2026-10-20 → 2026-10-31 (no day drift over 26 years).
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2000-01-31"))
    let now = fixtureDate("2026-10-20T00:00:00Z")
    XCTAssertEqual(cycle.resetAt(after: now), fixtureDate("2026-10-31T00:00:00Z"))
  }

  func testResetAtFutureAnchorReturnsAnchor() throws {
    // Future anchor 2027-03-31 vs now 2026-10-20 → returns anchor, no advance.
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2027-03-31"))
    let now = fixtureDate("2026-10-20T00:00:00Z")
    XCTAssertEqual(cycle.resetAt(after: now), fixtureDate("2027-03-31T00:00:00Z"))
  }

  func testResetAtOffsetAnchorAcrossDST() throws {
    // +02:00 anchor canonicalises to UTC 10:00; next month is Nov 20 UTC 10:00.
    // This crosses the Northern hemisphere DST boundary but uses UTC arithmetic.
    let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2026-10-20T12:00:00+02:00"))
    let now = fixtureDate("2026-10-21T00:00:00Z")
    XCTAssertEqual(cycle.resetAt(after: now), fixtureDate("2026-11-20T10:00:00Z"))
  }

  func testWindowsUseActualMonthLengthsAndStartAtPurchase() throws {
    for (anchor, now, start, end, days) in [
      ("2026-01-31", "2026-02-01T00:00:00Z", "2026-01-31T00:00:00Z", "2026-02-28T00:00:00Z", 28),
      ("2024-01-31", "2024-02-01T00:00:00Z", "2024-01-31T00:00:00Z", "2024-02-29T00:00:00Z", 29),
      ("2026-04-01", "2026-04-15T00:00:00Z", "2026-04-01T00:00:00Z", "2026-05-01T00:00:00Z", 30),
      ("2026-01-31", "2026-03-01T00:00:00Z", "2026-02-28T00:00:00Z", "2026-03-31T00:00:00Z", 31)
    ] {
      let cycle = try XCTUnwrap(MonthlyQuotaCycle(anchor: anchor))
      let window = try XCTUnwrap(cycle.window(containing: fixtureDate(now)))
      XCTAssertEqual(window.start, fixtureDate(start))
      XCTAssertEqual(window.end, fixtureDate(end))
      XCTAssertEqual(window.duration, Double(days * 86_400))
    }
    let future = try XCTUnwrap(MonthlyQuotaCycle(anchor: "2027-01-31"))
    XCTAssertNil(future.window(containing: fixtureDate("2026-10-20T00:00:00Z")))
  }
}
