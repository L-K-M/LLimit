import XCTest
@testable import QuotaCore

final class QuotaUtilitiesTests: XCTestCase {
  func testParseNumericParsesDifferentShapes() {
    XCTAssertEqual(parseNumeric(42), 42)
    XCTAssertEqual(parseNumeric("1,024"), 1024)
    XCTAssertEqual(parseNumeric("83.5%"), 83.5)
    XCTAssertNil(parseNumeric("abc"))
  }

  func testFormatShortDuration() {
    XCTAssertEqual(formatShortDuration(seconds: 65), "1m")
    XCTAssertEqual(formatShortDuration(seconds: 3661), "1h 1m")
    XCTAssertEqual(formatShortDuration(seconds: 90061), "1d 1h 1m")
  }

  func testResetCountdownHandlesPastAndFuture() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let past = now.addingTimeInterval(-1)
    let future = now.addingTimeInterval(3_700)

    XCTAssertEqual(formatResetCountdown(to: past, now: now), "reset")
    XCTAssertEqual(formatResetCountdown(to: future, now: now), "1h 1m")
  }

  func testParseISO8601SupportsCalendarDate() {
    let parsed = parseISO8601("2026-03-06")
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: parsed ?? Date.distantPast)

    XCTAssertNotNil(parsed)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 3)
    XCTAssertEqual(components.day, 6)
  }

  func testParseDateValueHandlesISOAndEpochTimestamps() {
    XCTAssertNotNil(parseDateValue("2026-03-06T12:00:00Z"))
    XCTAssertNotNil(parseDateValue("2026-03-06"))

    let epochSeconds = parseDateValue("1700000000")
    let epochMilliseconds = parseDateValue("1700000000000")

    XCTAssertNotNil(epochSeconds)
    XCTAssertNotNil(epochMilliseconds)

    let diff = abs((epochSeconds?.timeIntervalSince1970 ?? 0) - (epochMilliseconds?.timeIntervalSince1970 ?? 0))
    XCTAssertLessThan(diff, 1)
  }

  func testStartOfNextMonthReturnsCalendarBoundary() {
    var sourceComponents = DateComponents()
    sourceComponents.year = 2024
    sourceComponents.month = 3
    sourceComponents.day = 6
    sourceComponents.hour = 12
    let calendar = Calendar(identifier: .gregorian)
    let input = calendar.date(from: sourceComponents)

    guard let input else {
      XCTFail("Expected source date")
      return
    }

    let next = startOfNextMonth(from: input)
    let components = calendar.dateComponents([.year, .month, .day], from: next ?? Date.distantPast)

    XCTAssertNotNil(next)
    XCTAssertEqual(components.year, 2024)
    XCTAssertEqual(components.month, 4)
    XCTAssertEqual(components.day, 1)
  }
}
