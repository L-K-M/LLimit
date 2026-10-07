import XCTest
@testable import QuotaCore

final class QuotaFreshnessTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testCadencePolicyFloorLegacyFallbackAndBoundary() {
    for (interval, expected) in [(15, 3_600.0), (30, 3_600), (60, 7_200), (180, 21_600), (999, 21_600)] {
      XCTAssertEqual(QuotaFreshness.maxAge(refreshIntervalMinutes: interval), expected)
    }
    XCTAssertEqual(QuotaFreshness.maxAge(refreshIntervalMinutes: nil), 7_200)
    XCTAssertEqual(QuotaFreshness.maxAge(refreshIntervalMinutes: 0), 7_200)
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [], failures: [], refreshIntervalMinutes: 180)
    XCTAssertFalse(QuotaFreshness.isStale(fetchedAt: now.addingTimeInterval(-21_600), in: snapshot, now: now))
    XCTAssertTrue(QuotaFreshness.isStale(fetchedAt: now.addingTimeInterval(-21_601), in: snapshot, now: now))
    XCTAssertTrue(QuotaFreshness.isStale(fetchedAt: now.addingTimeInterval(-3_600), in: snapshot, now: now, maxAge: 60))
  }

  func testOptionalMetadataAndFailureTitleDecodeLegacyAndSurviveTransforms() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = Data(#"{"version":1,"generatedAt":"2023-11-14T22:13:20Z","providers":[],"failures":[{"provider":"kimi","kind":"auth","message":"expired"}]}"#.utf8)
    let decoded = try decoder.decode(QuotaSnapshot.self, from: legacy)
    XCTAssertNil(decoded.refreshIntervalMinutes)
    XCTAssertNil(decoded.failures.first?.title)
    var current = decoded
    current.refreshIntervalMinutes = 90
    XCTAssertEqual(current.mergingStaleUsage(from: decoded).refreshIntervalMinutes, 90)
    XCTAssertEqual(current.reconciled(with: []).refreshIntervalMinutes, 90)
    XCTAssertEqual(current.replacingResults(forAccountIDs: ["kimi"], from: decoded).refreshIntervalMinutes, 90)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode(QuotaSnapshot.self, from: encoder.encode(current)), current)
  }
}
