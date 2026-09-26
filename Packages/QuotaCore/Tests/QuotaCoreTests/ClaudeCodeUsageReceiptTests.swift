import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCodeUsageReceiptTests: XCTestCase {
  private let firstProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let secondProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

  func testFetchBeforeLoginCompletionCannotSuppressNewFetch() {
    let receipt = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(-1))
    XCTAssertFalse(receipt.satisfies(profileID: firstProfile, since: completedAt))
  }

  func testFetchAtOrAfterLoginCompletionSuppressesDuplicateFetch() {
    for interval: TimeInterval in [0, 1, 3600] {
      let receipt = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(interval))
      XCTAssertTrue(receipt.satisfies(profileID: firstProfile, since: completedAt))
    }
  }

  func testFreshReceiptFromPreviousLoginCannotSuppressNewProfileFetch() {
    let previousLogin = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(60))
    XCTAssertFalse(previousLogin.satisfies(profileID: secondProfile, since: completedAt))
  }

  func testTwoAccountReceiptsCannotSatisfyEachOthersFetch() {
    let first = ClaudeCodeUsageReceipt(profileID: firstProfile, fetchedAt: completedAt.addingTimeInterval(1))
    let second = ClaudeCodeUsageReceipt(profileID: secondProfile, fetchedAt: completedAt.addingTimeInterval(2))
    XCTAssertTrue(first.satisfies(profileID: firstProfile, since: completedAt))
    XCTAssertTrue(second.satisfies(profileID: secondProfile, since: completedAt))
    XCTAssertFalse(first.satisfies(profileID: secondProfile, since: completedAt))
    XCTAssertFalse(second.satisfies(profileID: firstProfile, since: completedAt))
  }
}
