import XCTest
@testable import QuotaCore

final class RetryAfterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testHeadersAreBoundedAndMalformedGuidanceIsIgnored() {
    XCTAssertEqual(parseRetryAfter(" 120 ", now: now), 120)
    XCTAssertEqual(parseRetryAfter("Tue, 14 Nov 2023 22:18:20 GMT", now: now), 300)
    XCTAssertEqual(parseRetryAfter("99999999999999999999", now: now), 86_400)
    XCTAssertEqual(parseRetryAfter("Thu, 14 Nov 2030 22:13:20 GMT", now: now), 86_400)
    for header in [nil, "", "0", "-10", "1.5", "1e6", "NaN", "Infinity", "120 seconds", "invalid",
                   "Tue, 14 Nov 2023 22:12:20 GMT", "Tue, 32 Nov 2023 22:18:20 GMT"] {
      XCTAssertNil(parseRetryAfter(header, now: now), "\(header ?? "nil")")
    }
  }

  func testFailureRetryAtIsAdditiveAndRoundTrips() throws {
    let legacy = #"{"provider":"anthropic","kind":"rateLimit","message":"limited"}"#
    XCTAssertNil(try JSONDecoder().decode(ProviderFailure.self, from: Data(legacy.utf8)).retryAt)
    let failure = ProviderFailure(provider: .anthropic, kind: .rateLimit, message: "limited", retryAt: now)
    XCTAssertEqual(try JSONDecoder().decode(ProviderFailure.self, from: JSONEncoder().encode(failure)), failure)
  }
}
