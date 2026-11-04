import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkQuotaCadenceTests: XCTestCase {
  func testInitialMeasurementRespectsDashboardReading() {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(BenchmarkQuotaCadence.delay(provider: .anthropic, lastAttempt: nil, lastObservation: now.addingTimeInterval(-20), now: now), 160)
    XCTAssertEqual(BenchmarkQuotaCadence.delay(provider: .anthropic, lastAttempt: nil, lastObservation: now.addingTimeInterval(-200), now: now), 0)
  }

  func testFailedAttemptAndClockSkewCannotCauseImmediateRetryOrUnboundedWait() {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(BenchmarkQuotaCadence.delay(provider: .anthropic, lastAttempt: now.addingTimeInterval(-5), lastObservation: now.addingTimeInterval(-500), now: now), 175)
    XCTAssertEqual(BenchmarkQuotaCadence.delay(provider: .anthropic, lastAttempt: now.addingTimeInterval(500), lastObservation: nil, now: now), 180)
  }

  func testUnobservedAndOtherProvidersHaveNoInventedDelay() {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(BenchmarkQuotaCadence.delay(provider: .anthropic, lastAttempt: nil, lastObservation: nil, now: now), 0)
    XCTAssertEqual(BenchmarkQuotaCadence.delay(provider: .openAI, lastAttempt: now, lastObservation: now, now: now), 0)
  }
}
