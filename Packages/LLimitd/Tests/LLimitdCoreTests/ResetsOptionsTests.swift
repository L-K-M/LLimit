import XCTest
@testable import LLimitdCore

final class ResetsOptionsTests: XCTestCase {
  func testDefaultsToHumanReadableSevenDays() throws {
    XCTAssertEqual(try parseResetsOptions([]), ResetsOptions(asJSON: false, days: 7))
  }

  func testParsesJSONAndDaysInAnyOrder() throws {
    XCTAssertEqual(
      try parseResetsOptions(["--json", "--days", "3"]),
      ResetsOptions(asJSON: true, days: 3)
    )
    XCTAssertEqual(
      try parseResetsOptions(["--days", "3", "--json"]),
      ResetsOptions(asJSON: true, days: 3)
    )
  }

  func testAcceptsTheDocumentedBoundaries() throws {
    XCTAssertEqual(try parseResetsOptions(["--days", "1"]).days, 1)
    XCTAssertEqual(try parseResetsOptions(["--days", "90"]).days, 90)
  }

  func testRejectsDaysOutsideTheDocumentedRange() {
    for value in ["0", "91", "-1", "500"] {
      XCTAssertThrowsError(try parseResetsOptions(["--days", value])) { error in
        XCTAssertEqual(error as? ResetsOptionError, .daysOutOfRange(Int(value)!))
        XCTAssertEqual((error as? ResetsOptionError)?.message, "--days must be between 1 and 90")
      }
    }
  }

  func testRejectsNonNumericAndMissingDaysValues() {
    XCTAssertThrowsError(try parseResetsOptions(["--days", "abc"])) { error in
      XCTAssertEqual(error as? ResetsOptionError, .invalidDaysValue("abc"))
      XCTAssertEqual((error as? ResetsOptionError)?.message, "--days needs a whole number of days")
    }
    XCTAssertThrowsError(try parseResetsOptions(["--days"])) { error in
      XCTAssertEqual(error as? ResetsOptionError, .missingDaysValue)
    }
  }

  func testRejectsUnknownOptions() {
    XCTAssertThrowsError(try parseResetsOptions(["--nope"])) { error in
      XCTAssertEqual(error as? ResetsOptionError, .unknownOption("--nope"))
      XCTAssertEqual((error as? ResetsOptionError)?.message, "unknown option: --nope")
    }
  }
}
