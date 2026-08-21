import XCTest
@testable import LLimitdCore

final class SettingsLockTests: XCTestCase {
  private var tempDirectory: URL!
  private var settingsFileURL: URL!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    settingsFileURL = tempDirectory.appendingPathComponent("quota-settings.json")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  func testLockFileLivesNextToSettingsFile() {
    let lock = SettingsLock(settingsFileURL: settingsFileURL)
    XCTAssertEqual(
      lock.lockFileURL.path,
      tempDirectory.appendingPathComponent("quota-settings.lock").path
    )
  }

  func testWithLockRunsBodyAndCreatesLockFile() throws {
    let lock = SettingsLock(settingsFileURL: settingsFileURL)
    let value = try lock.withLock { 41 + 1 }
    XCTAssertEqual(value, 42)
    XCTAssertTrue(FileManager.default.fileExists(atPath: lock.lockFileURL.path))
  }

  func testHeldLockExcludesIndependentAcquisition() throws {
    // flock is per open-file-description, so two SettingsLock instances in this
    // process contend exactly like two separate processes would.
    let holder = SettingsLock(settingsFileURL: settingsFileURL)
    let contender = SettingsLock(settingsFileURL: settingsFileURL)

    try holder.withLock {
      XCTAssertNil(try contender.tryAcquire(), "lock held concurrently: exclusion is broken")
    }

    let fd = try XCTUnwrap(try contender.tryAcquire(), "lock not released after withLock returned")
    contender.release(fd)
  }

  func testAsyncVariantHoldsLockAcrossSuspension() async throws {
    let holder = SettingsLock(settingsFileURL: settingsFileURL)
    let contender = SettingsLock(settingsFileURL: settingsFileURL)

    try await holder.withLock {
      try await Task.sleep(nanoseconds: 10_000_000)
      XCTAssertNil(try contender.tryAcquire(), "lock was not held across await")
      return 7
    }
  }

  func testDaemonExposesLockSidecarNextToSettings() {
    let paths = LinuxPaths(configHome: tempDirectory, dataHome: tempDirectory)
    let daemon = QuotaDaemon(paths: paths)
    XCTAssertEqual(
      daemon.settingsLock.lockFileURL.lastPathComponent,
      "quota-settings.lock"
    )
  }
}
