import XCTest
import QuotaCore
import LLimitdCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Retains PR #66's process boundary proof: rendering cannot reconcile or open settings.
final class CLIStatusTests: XCTestCase {
  private enum SettingsFixture: CaseIterable {
    case missing, corrupt, unreadable, unrelatedAccount
  }

  private var directory: URL!
  private var paths: LinuxPaths!
  private let credentialSentinel = "status-test-credential-must-not-appear"
  private let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    paths = LinuxPaths(configHome: directory.appendingPathComponent("config"), dataHome: directory.appendingPathComponent("data"))
  }

  override func tearDown() {
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.settingsFileURL.path)
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  func testStatusIgnoresSettingsAndPreservesSnapshot() throws {
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(
      accountID: "cached", provider: .anthropic, title: "Stored Claude",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 62)], fetchedAt: now
    )], failures: [])
    for fixture in SettingsFixture.allCases {
      try prepareSettings(fixture)
      try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
      try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: paths.snapshotFileURL.path)
      let before = try Data(contentsOf: paths.snapshotFileURL)
      for options in [[], ["--json"]] as [[String]] {
        let result = try runCLI(["status"] + options)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(result.stdout.contains(credentialSentinel))
        let expected = options.isEmpty ? StatusRenderer.humanReadable(snapshot: snapshot) : StatusRenderer.waybarJSON(snapshot: snapshot)
        XCTAssertEqual(result.stdout, expected + "\n")
        XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.snapshotFileURL.path)[.modificationDate] as? Date, modificationDate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.historyFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory.appendingPathComponent("quota-settings.lock").path))
      }
      if fixture == .missing {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configHome.path))
      }
    }
  }

  func testMissingAndCorruptSnapshotDoNotWrite() throws {
    try prepareSettings(.corrupt)
    for corrupt in [false, true] {
      if corrupt {
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        try Data("not a snapshot".utf8).write(to: paths.snapshotFileURL)
      }
      for options in [[], ["--json"]] as [[String]] {
        let result = try runCLI(["status"] + options)
        XCTAssertEqual(result.code, 0)
        let expected = options.isEmpty ? StatusRenderer.humanReadable(snapshot: nil) : StatusRenderer.waybarJSON(snapshot: nil)
        XCTAssertEqual(result.stdout, expected + "\n")
      }
      if corrupt {
        XCTAssertEqual(try String(contentsOf: paths.snapshotFileURL, encoding: .utf8), "not a snapshot")
      } else {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.dataDirectory.path))
      }
    }
  }

  func testEveryDisplayCommandNeverOpensSettingsFIFOOrRewritesCache() throws {
    try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
    XCTAssertEqual(mkfifo(paths.settingsFileURL.path, 0o600), 0)
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let snapshot = QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(accountID: "cached", provider: .anthropic, title: "Work",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 62)], fetchedAt: now)], failures: [], refreshIntervalMinutes: 180)
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: paths.snapshotFileURL.path)
    let before = try Data(contentsOf: paths.snapshotFileURL)
    for args in [["status"], ["status", "--json"], ["status", "--compact"], ["status", "--format", "{name}"],
                 ["check"], ["check", "anthropic"], ["pick"], ["resets"], ["resets", "--json"]] {
      let result = try runCLI(args)
      XCTAssertEqual(result.code, 0, "\(args): \(result.stderr)")
      XCTAssertEqual(result.stderr, "", "\(args)")
      XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), before)
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.snapshotFileURL.path)[.modificationDate] as? Date, modificationDate)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory.appendingPathComponent("quota-settings.lock").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.historyFileURL.path))
  }

  func testExportReadsOnlyHistoryAndDoesNotCapEntries() throws {
    try prepareSettings(.corrupt)
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let history = (0..<3_001).map { index in
      QuotaSnapshot(generatedAt: now.addingTimeInterval(-Double(index)), providers: [], failures: [], refreshIntervalMinutes: 30)
    }
    try QuotaHistoryStore(fileURL: paths.historyFileURL).save(history)
    let before = try Data(contentsOf: paths.historyFileURL)
    let result = try runCLI(["export", "--days", "1", "--format", "JSON"])
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.stderr, "")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode([QuotaSnapshot].self, from: Data(result.stdout.utf8)).count, 3_001)
    XCTAssertEqual(try Data(contentsOf: paths.historyFileURL), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshotFileURL.path))
  }

  func testWatchReopensSnapshotAndPipesCleanJSON() throws {
    try prepareSettings(.corrupt)
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    var snapshot = QuotaSnapshot(generatedAt: now, providers: [ProviderUsage(accountID: "cached", provider: .anthropic, title: "First",
      metrics: [UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 62)], fetchedAt: now)], failures: [])
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    let process = configuredProcess(["status", "--json", "--watch=1s"])
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let first = try readFrame(output.fileHandleForReading)
    XCTAssertFalse(first.isEmpty)
    snapshot.providers[0].title = "Second"
    try SnapshotStore(fileURL: paths.snapshotFileURL).save(snapshot)
    let second = try readFrame(output.fileHandleForReading)
    process.terminate()
    process.waitUntilExit()
    for data in [first, second] {
      XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\u{1B}"))
    }
    XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("First"))
    XCTAssertTrue(String(decoding: second, as: UTF8.self).contains("Second"))
  }

  func testCLIExitContractAndVersion() throws {
    try prepareSettings(.corrupt)
    XCTAssertEqual(try runCLI(["check"]).code, 3)
    XCTAssertEqual(try runCLI(["check", "--min", "101"]).code, 64)
    let pick = try runCLI(["pick"])
    XCTAssertEqual(pick.code, 3)
    XCTAssertEqual(pick.stdout, "")
    XCTAssertEqual(try runCLI(["status", "--watch", "0"]).code, 64)
    XCTAssertEqual(try runCLI(["--version"]).stdout, "llimit \(LLimitdInfo.version) (LLimitd, QuotaCore)\n")
  }

  private func prepareSettings(_ fixture: SettingsFixture) throws {
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.settingsFileURL.path)
    try? FileManager.default.removeItem(at: paths.configHome)
    guard fixture != .missing else { return }
    try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
    if fixture == .corrupt {
      try Data("not json \(credentialSentinel)".utf8).write(to: paths.settingsFileURL)
      return
    }
    try SettingsStore(fileURL: paths.settingsFileURL).save(AppSettings(accounts: [ProviderAccount(
      id: "settings-only", provider: .anthropic, credentials: [CredentialField.anthropicAccessToken: credentialSentinel]
    )]))
    if fixture == .unreadable {
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.settingsFileURL.path)
    }
  }

  private func runCLI(_ args: [String]) throws -> (stdout: String, stderr: String, code: Int32) {
    let process = configuredProcess(args)
    let output = Pipe(), error = Pipe()
    process.standardOutput = output
    process.standardError = error
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    // Drain stdout concurrently: JSON exports can exceed a pipe's capacity.
    let data = CapturedOutput()
    let readDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      data.set(output.fileHandleForReading.readDataToEndOfFile())
      readDone.signal()
    }
    if finished.wait(timeout: .now() + 10) == .timedOut {
      process.terminate()
      XCTFail("CLI blocked, possibly opening settings: \(args)")
    }
    process.waitUntilExit()
    XCTAssertEqual(readDone.wait(timeout: .now() + 5), .success)
    return (String(decoding: data.get(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), process.terminationStatus)
  }

  private func readFrame(_ handle: FileHandle) throws -> Data {
    let data = CapturedOutput()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      data.set(handle.availableData)
      finished.signal()
    }
    guard finished.wait(timeout: .now() + 5) == .success else {
      throw NSError(domain: "CLIStatusTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Watch produced no frame within 5 seconds"])
    }
    return data.get()
  }

  private func configuredProcess(_ args: [String]) -> Process {
    var build = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    #if os(macOS)
    build = build.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #endif
    let process = Process()
    process.executableURL = build.appendingPathComponent("llimit")
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = directory.path
    environment["XDG_CONFIG_HOME"] = paths.configHome.path
    environment["XDG_DATA_HOME"] = paths.dataHome.path
    environment["XDG_CACHE_HOME"] = directory.appendingPathComponent("cache").path
    environment["XDG_STATE_HOME"] = directory.appendingPathComponent("state").path
    process.environment = environment
    return process
  }
}

private final class CapturedOutput: @unchecked Sendable {
  private var data = Data()
  private let lock = NSLock()
  func set(_ value: Data) {
    lock.lock()
    defer { lock.unlock() }
    data = value
  }
  func get() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
