import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkCredentialRevisionTests: XCTestCase {
  func testUntrackedCredentialsKeepTheirCurrentRevision() {
    let tracker = BenchmarkCredentialRevision()
    let explicit = UUID()
    XCTAssertNil(tracker.ownership(of: nil))
    XCTAssertEqual(tracker.ownership(of: explicit), explicit)
  }

  func testRepeatedVerifiedRenewalsPreserveAnInitialNilOwnershipRevision() {
    var tracker = BenchmarkCredentialRevision()
    let first = UUID()
    let second = UUID()
    tracker.recordVerifiedRenewal(from: nil, to: first)
    XCTAssertNil(tracker.ownership(of: first))
    tracker.recordVerifiedRenewal(from: first, to: second)
    XCTAssertNil(tracker.ownership(of: second))
  }

  func testRepeatedVerifiedRenewalsPreserveAnExistingOwnershipRevision() {
    var tracker = BenchmarkCredentialRevision()
    let baseline = UUID()
    let first = UUID()
    let second = UUID()
    tracker.recordVerifiedRenewal(from: baseline, to: first)
    tracker.recordVerifiedRenewal(from: first, to: second)
    XCTAssertEqual(tracker.ownership(of: second), baseline)
  }

  func testExplicitEditBreaksOldOwnershipAndItsRenewalKeepsTheNewOwnership() {
    var tracker = BenchmarkCredentialRevision()
    let original = UUID()
    let renewed = UUID()
    let edited = UUID()
    let renewedEdit = UUID()
    tracker.recordVerifiedRenewal(from: original, to: renewed)
    XCTAssertEqual(tracker.ownership(of: edited), edited)
    tracker.recordVerifiedRenewal(from: edited, to: renewedEdit)
    XCTAssertEqual(tracker.ownership(of: renewedEdit), edited)
    XCTAssertNotEqual(tracker.ownership(of: renewedEdit), original)
  }

  func testAnOldOrUnrelatedRevisionCannotUseTheLatestRenewalOwnership() {
    var tracker = BenchmarkCredentialRevision()
    let baseline = UUID()
    let first = UUID()
    let second = UUID()
    let unrelated = UUID()
    tracker.recordVerifiedRenewal(from: baseline, to: first)
    tracker.recordVerifiedRenewal(from: first, to: second)
    XCTAssertEqual(tracker.ownership(of: first), first)
    XCTAssertEqual(tracker.ownership(of: unrelated), unrelated)
    XCTAssertNil(tracker.ownership(of: nil))
  }
}
