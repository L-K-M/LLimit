import Foundation
import XCTest
@testable import QuotaCore

final class CodexProfileStoreTests: XCTestCase {
  private var temporary: URL!
  private var store: CodexProfileStore!

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    store = CodexProfileStore(root: temporary.appendingPathComponent("profiles"))
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
  }

  func testProfilesStaySeparateAndUsePrivatePermissions() throws {
    let first = CodexAccountProfile(), second = CodexAccountProfile()
    let directory = try store.prepare(first)
    let other = try store.prepare(second)
    XCTAssertNotEqual(directory, other)
    for path in [store.root, directory, directory.appendingPathComponent("work"), other] {
      XCTAssertEqual(try permissions(path), 0o700)
    }
    let auth = directory.appendingPathComponent("auth.json")
    try codexTestAuthentication().write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)
    XCTAssertEqual(try store.identity(first).accountID, "workspace-one")
    XCTAssertEqual(try permissions(auth), 0o600)
  }

  func testMarkerIsExclusiveAcrossStoreInstancesAndProtectsRemoval() throws {
    let profile = CodexAccountProfile()
    let directory = try store.prepare(profile)
    try store.acquire(profile)
    let second = CodexProfileStore(root: store.root)
    XCTAssertTrue(second.hasPendingOperation(profile))
    XCTAssertThrowsError(try second.acquire(profile)) { error in
      guard case CodexConnectionError.unfinishedOperation = error else { return XCTFail("Wrong error: \(error)") }
    }
    XCTAssertFalse(try second.remove(profile))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    let operations = store.root.appendingPathComponent("Operations")
    XCTAssertEqual(try permissions(operations), 0o700)
    let files = try FileManager.default.contentsOfDirectory(at: operations, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(try permissions(XCTUnwrap(files.first)), 0o600)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)).count, 0)
    try store.release(profile)
    XCTAssertTrue(try second.remove(profile))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertFalse(second.hasPendingOperation(profile))
  }

  func testRejectsProfileAndAuthSymlinksWithoutChangingTarget() throws {
    let profile = CodexAccountProfile()
    let directory = try store.prepare(profile)
    let outside = temporary.appendingPathComponent("outside.json")
    try codexTestAuthentication().write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("auth.json"), withDestinationURL: outside)
    XCTAssertThrowsError(try store.identity(profile))
    XCTAssertEqual(try permissions(outside), 0o644)

    let linkedProfile = CodexAccountProfile()
    try FileManager.default.createSymbolicLink(at: store.directory(for: linkedProfile), withDestinationURL: directory)
    XCTAssertThrowsError(try store.prepare(linkedProfile))
    XCTAssertThrowsError(try store.remove(linkedProfile))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }

  func testRejectsDanglingProfileSymlinkDuringRemoval() throws {
    let profile = CodexAccountProfile()
    _ = try store.prepare(CodexAccountProfile())
    let link = store.directory(for: profile)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temporary.appendingPathComponent("missing"))
    XCTAssertThrowsError(try store.remove(profile))
    XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    XCTAssertTrue(store.hasPendingOperation(profile))
  }

  func testRejectsSymlinkedOperationsDirectory() throws {
    _ = try store.prepare(CodexAccountProfile())
    let outside = temporary.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("Operations"), withDestinationURL: outside)
    XCTAssertThrowsError(try store.acquire(CodexAccountProfile()))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  private func permissions(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
  }
}

func codexTestAuthentication(accountID: String = "workspace-one", userID: String = "user-one") throws -> Data {
  let claims: [String: Any] = [
    "sub": userID, "email": "test@example.invalid",
    "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_user_id": userID]
  ]
  let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
    "access_token": "fake-access", "refresh_token": "fake-refresh", "id_token": "header.\(payload).signature", "account_id": accountID
  ]])
}
