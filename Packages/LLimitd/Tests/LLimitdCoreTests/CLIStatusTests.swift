import XCTest
import QuotaCore
import LLimitdCore

final class CLIStatusTests: XCTestCase {
  private enum SettingsFixture {
    case missing
    case corrupt
    case unreadable
    case unrelatedAccount
  }

  private var tempDirectory: URL!
  private var paths: LinuxPaths!
  private let credentialSentinel = "status-test-credential-must-not-appear"
  private let snapshotModificationDate = Date(timeIntervalSince1970: 1_700_000_000)

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = LinuxPaths(
      configHome: tempDirectory.appendingPathComponent("config", isDirectory: true),
      dataHome: tempDirectory.appendingPathComponent("data", isDirectory: true)
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  func testStatusPreservesSnapshotWithMissingSettings() throws {
    try assertStatusPreservesSnapshot(settings: .missing)
  }

  func testStatusPreservesSnapshotWithCorruptSettings() throws {
    try assertStatusPreservesSnapshot(settings: .corrupt)
  }

  func testStatusPreservesSnapshotWithUnreadableSettings() throws {
    try assertStatusPreservesSnapshot(settings: .unreadable)
  }

  func testStatusIgnoresAccountsAndCredentialsInValidSettings() throws {
    try assertStatusPreservesSnapshot(settings: .unrelatedAccount)
  }

  func testStatusWithoutSnapshotKeepsNoDataContract() throws {
    try prepareSettings(.corrupt)
    try assertOutput(snapshot: nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.dataDirectory.path))
  }

  func testStatusWithCorruptSnapshotKeepsNoDataContractWithoutWriting() throws {
    try prepareSettings(.corrupt)
    try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
    try Data("not a snapshot".utf8).write(to: paths.snapshotFileURL)
    try setSnapshotModificationDate()
    let before = try Data(contentsOf: paths.snapshotFileURL)

    try assertOutput(snapshot: nil)

    try assertSnapshotUnchanged(before)
  }

  private func assertStatusPreservesSnapshot(settings fixture: SettingsFixture) throws {
    try prepareSettings(fixture)
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let snapshot = QuotaSnapshot(
      generatedAt: now,
      providers: [ProviderUsage(
        accountID: "cached-claude", provider: .anthropic, title: "Stored Claude",
        metrics: [
          UsageMetric(id: "session", label: "Session", remainingPercent: 62, resetIn: "3h 12m"),
          UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 41, resetIn: "4d 2h")
        ],
        fetchedAt: now
      )],
      failures: [ProviderFailure(accountID: "cached-kimi", provider: .kimi, kind: .auth, message: "Token expired")]
    )

    // Reset the fixture for each format so both commands must preserve the original cache.
    for options in [["--json"], []] as [[String]] {
      try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
      try setSnapshotModificationDate()
      let before = try Data(contentsOf: paths.snapshotFileURL)

      try assertOutput(snapshot: snapshot, options: options)

      try assertSnapshotUnchanged(before)
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.historyFileURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory.appendingPathComponent("quota-settings.lock").path))
    }
    if case .missing = fixture {
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configHome.path))
    }
  }

  private func prepareSettings(_ fixture: SettingsFixture) throws {
    if case .missing = fixture { return }

    try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
    if case .corrupt = fixture {
      try Data("not json \(credentialSentinel)".utf8).write(to: paths.settingsFileURL)
      return
    }

    let account = ProviderAccount(
      id: "settings-only", provider: .anthropic, displayName: "Settings-only account",
      credentials: [CredentialField.anthropicAccessToken: credentialSentinel]
    )
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [account]))
    guard case .unreadable = fixture else { return }

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.settingsFileURL.path)
    guard (try? Data(contentsOf: paths.settingsFileURL)) == nil else {
      throw XCTSkip("This user can read mode-000 files; unreadable-settings fixture cannot be enforced.")
    }
  }

  private func assertOutput(snapshot: QuotaSnapshot?, options: [String]? = nil) throws {
    let formats = options.map { [$0] } ?? [["--json"], []]
    for options in formats {
      let result = try runStatus(options)
      XCTAssertEqual(result.exitCode, 0)
      XCTAssertTrue(result.stderr.isEmpty, result.stderr)
      XCTAssertFalse(result.stdout.contains(credentialSentinel))
      XCTAssertFalse(result.stdout.contains("[llimitd]"))

      if options.contains("--json") {
        // Parse all stdout: extra logs or a second JSON object must fail the contract.
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        XCTAssertNotNil(object as? [String: Any])
        XCTAssertEqual(result.stdout, StatusRenderer.waybarJSON(snapshot: snapshot) + "\n")
      } else {
        XCTAssertEqual(result.stdout, StatusRenderer.humanReadable(snapshot: snapshot) + "\n")
      }
    }
  }

  private func runStatus(_ options: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
    var buildDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    #if os(macOS)
    // XCTest executables live inside <build>/<name>.xctest/Contents/MacOS.
    buildDirectory = buildDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #endif
    let executable = buildDirectory.appendingPathComponent("llimit")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "Missing CLI at \(executable.path)")

    let process = Process()
    process.executableURL = executable
    process.arguments = ["status"] + options
    // Keep runtime-library paths, but isolate every home/XDG path from real credentials.
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = tempDirectory.path
    environment["XDG_CONFIG_HOME"] = paths.configHome.path
    environment["XDG_DATA_HOME"] = paths.dataHome.path
    environment["XDG_CACHE_HOME"] = tempDirectory.appendingPathComponent("cache").path
    environment["XDG_STATE_HOME"] = tempDirectory.appendingPathComponent("state").path
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (
      String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      process.terminationStatus
    )
  }

  private func setSnapshotModificationDate() throws {
    try FileManager.default.setAttributes([.modificationDate: snapshotModificationDate], ofItemAtPath: paths.snapshotFileURL.path)
  }

  private func assertSnapshotUnchanged(_ before: Data) throws {
    XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), before)
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.snapshotFileURL.path)
    XCTAssertEqual(attributes[.modificationDate] as? Date, snapshotModificationDate)
  }
}
