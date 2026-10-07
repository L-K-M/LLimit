import XCTest
@testable import QuotaCore
@testable import LLimitdCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class QuotaAlertsTests: XCTestCase {
  private var tempDirectory: URL!
  private var logLines: [String] = []
  private let logLock = NSLock()

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    logLines = []
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    super.tearDown()
  }

  private var paths: LinuxPaths {
    LinuxPaths(
      configHome: tempDirectory.appendingPathComponent("config", isDirectory: true),
      dataHome: tempDirectory.appendingPathComponent("data", isDirectory: true)
    )
  }

  private func log(_ line: String) {
    logLock.lock()
    logLines.append(line)
    logLock.unlock()
  }

  private var loggedText: String {
    logLock.lock()
    defer { logLock.unlock() }
    return logLines.joined(separator: "\n")
  }

  /// Writes an executable shell script into the temp directory.
  @discardableResult
  private func script(_ name: String, _ body: String, in directory: URL? = nil) throws -> URL {
    let directory = directory ?? tempDirectory!
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func event(_ kind: QuotaEventKind = .threshold) -> QuotaEvent {
    QuotaEvent(
      kind: kind,
      severity: .critical,
      accountID: "acct-1",
      accountName: "Claude Work",
      provider: .anthropic,
      metricID: "five_hour",
      metricLabel: "5-hour limit",
      remainingPercent: 4,
      threshold: 5,
      resetAt: Date(timeIntervalSince1970: 1_800_007_200)
    )
  }

  // MARK: - Options

  func testAlertsAreOffByDefault() throws {
    let options = try DaemonAlertOptions.parse(arguments: [], environment: [:])
    XCTAssertFalse(options.isDeliveryEnabled)
    XCTAssertEqual(options.thresholds, [20, 5])
    XCTAssertNil(try QuotaAlertMonitor.make(options: options, paths: paths, environment: [:], log: log))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.alertsStateFileURL.path))
  }

  func testParsesFlags() throws {
    let options = try DaemonAlertOptions.parse(
      arguments: ["--notify", "--on-event", "/opt/hook", "--thresholds", "10, 30,10"],
      environment: [:]
    )
    XCTAssertTrue(options.desktopNotifications)
    XCTAssertEqual(options.hookCommand, "/opt/hook")
    XCTAssertEqual(options.thresholds, [30, 10])
  }

  func testNotifyEnvironmentVariable() throws {
    for value in ["1", "true", "YES", "on"] {
      XCTAssertTrue(try DaemonAlertOptions.parse(arguments: [], environment: ["LLIMIT_NOTIFY": value]).desktopNotifications, value)
    }
    for value in ["", "0", "false", "off"] {
      XCTAssertFalse(try DaemonAlertOptions.parse(arguments: [], environment: ["LLIMIT_NOTIFY": value]).desktopNotifications, value)
    }
    XCTAssertThrowsError(try DaemonAlertOptions.parse(arguments: [], environment: ["LLIMIT_NOTIFY": "2"])) {
      XCTAssertEqual($0 as? DaemonAlertError, .invalidNotifySetting("2"))
    }
  }

  func testRejectsInvalidArguments() {
    let cases: [([String], DaemonAlertError)] = [
      (["--notfy"], .unknownOption("--notfy")),
      (["--on-event"], .missingValue("--on-event")),
      (["--on-event", ""], .missingValue("--on-event")),
      (["--thresholds"], .missingValue("--thresholds")),
      (["--thresholds", "0"], .invalidThresholds("0")),
      (["--thresholds", "100"], .invalidThresholds("100")),
      (["--thresholds", "20,"], .invalidThresholds("20,")),
      (["--thresholds", ","], .invalidThresholds(",")),
      (["--thresholds", "150"], .invalidThresholds("150")),
      (["--thresholds", "twenty"], .invalidThresholds("twenty"))
    ]
    for (arguments, expected) in cases {
      XCTAssertThrowsError(try DaemonAlertOptions.parse(arguments: arguments, environment: [:]), "\(arguments)") {
        XCTAssertEqual($0 as? DaemonAlertError, expected)
      }
    }
  }

  // MARK: - Setup

  func testMissingHookIsAnError() throws {
    var options = DaemonAlertOptions()
    options.hookCommand = "llimit-no-such-hook"

    XCTAssertThrowsError(try QuotaAlertMonitor.make(options: options, paths: paths, environment: ["PATH": tempDirectory.path], log: log)) {
      XCTAssertEqual($0 as? DaemonAlertError, .hookNotFound("llimit-no-such-hook"))
    }
  }

  func testMissingNotifySendWarnsOnceAndDisablesOnlyNotifications() throws {
    var options = DaemonAlertOptions()
    options.desktopNotifications = true
    let emptyPath = ["PATH": tempDirectory.appendingPathComponent("empty-bin").path]

    XCTAssertNil(try QuotaAlertMonitor.make(options: options, paths: paths, environment: emptyPath, log: log))
    XCTAssertEqual(logLines.filter { $0.contains("notify-send is not on PATH") }.count, 1)

    options.hookCommand = try script("hook", "exit 0").path
    XCTAssertNotNil(try QuotaAlertMonitor.make(options: options, paths: paths, environment: emptyPath, log: log))
  }

  func testFindsNotifySendOnPath() throws {
    let bin = tempDirectory.appendingPathComponent("bin", isDirectory: true)
    try script("notify-send", "exit 0", in: bin)
    var options = DaemonAlertOptions()
    options.desktopNotifications = true

    let monitor = try QuotaAlertMonitor.make(options: options, paths: paths, environment: ["PATH": "/nonexistent:\(bin.path)"], log: log)

    XCTAssertNotNil(monitor)
    XCTAssertTrue(loggedText.contains("desktop notifications via \(bin.path)/notify-send"))
  }

  func testThresholdsWithoutDeliveryWarn() throws {
    let options = try DaemonAlertOptions.parse(arguments: ["--thresholds", "30"], environment: [:])
    XCTAssertNil(try QuotaAlertMonitor.make(options: options, paths: paths, environment: [:], log: log))
    XCTAssertTrue(loggedText.contains("--thresholds has no effect"))
  }

  func testExecutableLocatorSkipsDirectoriesAndNonExecutables() throws {
    let first = tempDirectory.appendingPathComponent("first", isDirectory: true)
    let second = tempDirectory.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first.appendingPathComponent("tool"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: second.appendingPathComponent("tool"))
    let third = tempDirectory.appendingPathComponent("third", isDirectory: true)
    let tool = try script("tool", "exit 0", in: third)

    let environment = ["PATH": "::\(first.path):\(second.path):\(third.path)"]
    XCTAssertEqual(ExecutableLocator.find("tool", environment: environment)?.path, tool.path)
    XCTAssertEqual(ExecutableLocator.find(tool.path, environment: [:])?.path, tool.path)
    XCTAssertNil(ExecutableLocator.find(second.appendingPathComponent("tool").path, environment: [:]))
    XCTAssertNil(ExecutableLocator.find("tool", environment: [:]))
  }

  // MARK: - Payloads

  func testHookEnvironmentCarriesOnlyTheEvent() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let base = ["PATH": "/usr/bin", "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus", "LLIMIT_NOTIFY": "1", "LLIMIT_EVENT": "stale"]

    let environment = EventHookSink.environment(for: event(), now: now, inheriting: base)

    XCTAssertEqual(environment["PATH"], "/usr/bin")
    XCTAssertEqual(environment["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/1000/bus")
    let payload = environment.filter { $0.key.hasPrefix("LLIMIT_") }
    XCTAssertEqual(payload, [
      "LLIMIT_EVENT": "threshold",
      "LLIMIT_SEVERITY": "critical",
      "LLIMIT_ACCOUNT_ID": "acct-1",
      "LLIMIT_ACCOUNT_NAME": "Claude Work",
      "LLIMIT_PROVIDER": "anthropic",
      "LLIMIT_SUMMARY": "Claude Work: 5-hour limit low",
      "LLIMIT_BODY": "4% left, resets in 2h.",
      "LLIMIT_METRIC": "five_hour",
      "LLIMIT_METRIC_LABEL": "5-hour limit",
      "LLIMIT_REMAINING": "4",
      "LLIMIT_THRESHOLD": "5",
      "LLIMIT_RESETS_AT": "2027-01-15T10:00:00Z"
    ])
  }

  func testHookEnvironmentForAFailureHasNoMetricFields() {
    let failure = QuotaEvent(kind: .failure, severity: .critical, accountID: "a", accountName: "ChatGPT", provider: .openAI, failureKind: .auth)
    let payload = EventHookSink.environment(for: failure, now: Date(), inheriting: [:])

    XCTAssertEqual(payload["LLIMIT_EVENT"], "failure")
    XCTAssertEqual(payload["LLIMIT_FAILURE_KIND"], "auth")
    for key in ["LLIMIT_METRIC", "LLIMIT_METRIC_LABEL", "LLIMIT_REMAINING", "LLIMIT_THRESHOLD", "LLIMIT_RESETS_AT", "LLIMIT_ESTIMATED"] {
      XCTAssertNil(payload[key], key)
    }
  }

  func testNotifySendArguments() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(
      DesktopNotificationSink.arguments(for: event(), now: now),
      ["--app-name=LLimit", "--urgency=critical", "--", "Claude Work: 5-hour limit low", "4% left, resets in 2h."]
    )
    XCTAssertEqual(DesktopNotificationSink.arguments(for: event(.reset), now: now)[1], "--urgency=critical")
    var normal = event(.reset)
    normal.severity = .normal
    XCTAssertEqual(DesktopNotificationSink.arguments(for: normal, now: now)[1], "--urgency=normal")
  }

  // MARK: - Child processes

  func testRunnerReportsExitStatusAndLaunchFailure() throws {
    let runner = ChildProcessRunner(log: log)
    var outcomes: [ChildProcessRunner.Outcome] = []
    let lock = NSLock()
    let record = { (outcome: ChildProcessRunner.Outcome) in
      lock.lock()
      outcomes.append(outcome)
      lock.unlock()
    }

    runner.run(executable: try script("ok", "exit 0"), arguments: [], environment: [:], completion: record)
    runner.run(executable: try script("fails", "exit 3"), arguments: [], environment: [:], completion: record)
    runner.run(executable: tempDirectory.appendingPathComponent("missing"), arguments: [], environment: [:], completion: record)
    runner.waitUntilIdle()

    XCTAssertEqual(outcomes, [.exited(0), .exited(3), .failedToLaunch])
    XCTAssertTrue(loggedText.contains("fails exited with status 3"))
    XCTAssertTrue(loggedText.contains("Could not start missing"))
  }

  func testHungHookDoesNotBlockAndIsKilledAndReaped() throws {
    let pidFile = tempDirectory.appendingPathComponent("pid")
    // Ignores SIGTERM, so only the SIGKILL escalation can stop it.
    let hung = try script("hung", "trap '' TERM\necho $$ > \"\(pidFile.path)\"\nwhile :; do sleep 0.1; done")
    let runner = ChildProcessRunner(timeout: 0.5, log: log)
    let finished = expectation(description: "hook stopped")
    var outcome: ChildProcessRunner.Outcome?

    let start = Date()
    runner.run(executable: hung, arguments: [], environment: [:]) {
      outcome = $0
      finished.fulfill()
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.25, "run must not wait for the child")

    wait(for: [finished], timeout: 10)
    XCTAssertEqual(outcome, .timedOut)
    XCTAssertTrue(loggedText.contains("hung did not finish within"))

    // kill(pid, 0) still succeeds for a zombie: ESRCH means the child was reaped.
    let pid = try XCTUnwrap(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    let reaped = expectation(description: "child reaped")
    DispatchQueue.global().async {
      for _ in 0..<50 where kill(pid, 0) == 0 {
        usleep(100_000)
      }
      if kill(pid, 0) != 0, errno == ESRCH {
        reaped.fulfill()
      }
    }
    wait(for: [reaped], timeout: 10)
  }

  func testHookStopsOnSIGTERMEvenThoughTheDaemonIgnoresIt() throws {
    // The daemon ignores SIGTERM and SIGINT to shut down through dispatch
    // sources. Ignored dispositions survive exec, so the child must be
    // spawned with defaults or it could never be stopped politely.
    let previousTERM = signal(SIGTERM, SIG_IGN)
    let previousINT = signal(SIGINT, SIG_IGN)
    defer {
      signal(SIGTERM, previousTERM)
      signal(SIGINT, previousINT)
    }

    let runner = ChildProcessRunner(timeout: 0.3, log: log)
    var outcome: ChildProcessRunner.Outcome?
    runner.run(executable: try script("sleeper", "exec sleep 30"), arguments: [], environment: [:]) { outcome = $0 }
    runner.waitUntilIdle()

    XCTAssertEqual(outcome, .timedOut)
    XCTAssertFalse(loggedText.contains("ignored SIGTERM"), loggedText)
  }

  #if os(Linux)
  func testChildDoesNotInheritDaemonDescriptors() throws {
    // Like the settings lock: opened without O_CLOEXEC.
    let held = tempDirectory.appendingPathComponent("held")
    let descriptor = open(held.path, O_WRONLY | O_CREAT, 0o600)
    XCTAssertGreaterThan(descriptor, 2)
    defer { close(descriptor) }
    let listing = tempDirectory.appendingPathComponent("fds")

    // Compares what the hook's descriptors point to: the numbers alone can
    // collide with descriptors the shell opens for itself.
    let runner = ChildProcessRunner(log: log)
    let lister = try script("list-fds", "for f in /proc/$$/fd/*; do readlink \"$f\"; done > \"\(listing.path)\"")
    runner.run(executable: lister, arguments: [], environment: ["PATH": "/usr/bin:/bin"])
    runner.waitUntilIdle()

    let targets = try String(contentsOf: listing, encoding: .utf8).split(separator: "\n").map(String.init)
    XCTAssertTrue(targets.contains("/dev/null"), "\(targets)")
    XCTAssertFalse(targets.contains(held.resolvingSymlinksInPath().path), "\(targets)")
  }
  #endif

  // MARK: - End to end

  func testDaemonDeliversFailureOnceAcrossRestartsThenRecovery() async throws {
    let secret = "sk-ant-oat-alert-test-secret"
    let output = tempDirectory.appendingPathComponent("hook-output")
    let hook = try script("record-event", "{ env | grep '^LLIMIT_' | sort; echo ---; } >> \"$HOOK_OUTPUT\"")
    let client = ScriptedClient()
    client.error = ProviderClientError(kind: .auth, message: "401: token \(secret) was rejected")

    let daemon = QuotaDaemon(
      paths: paths,
      coordinator: QuotaCoordinator(clients: [client]),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.tempDirectory]) },
      log: { _ in }
    )
    daemon.loadConfiguration()
    daemon.addAccount(provider: .anthropic, displayName: "Claude Work", credentials: [CredentialField.anthropicAccessToken: secret])

    func attachMonitor() -> ChildProcessRunner {
      let runner = ChildProcessRunner(log: log)
      let sink = EventHookSink(executable: hook, runner: runner, inheritedEnvironment: ["HOOK_OUTPUT": output.path, "PATH": "/usr/bin:/bin"])
      let monitor = QuotaAlertMonitor(stateFileURL: paths.alertsStateFileURL, config: .default, sinks: [sink], log: log)
      daemon.onSnapshotSaved = { previous, current in
        let names = daemon.settings.accounts.map { ($0.id, $0.resolvedDisplayName) }
        monitor.process(previous: previous, current: current, accountNames: Dictionary(names) { first, _ in first })
      }
      return runner
    }
    func deliveredEvents() -> [String] {
      let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
      return text.split(separator: "\n").filter { $0.hasPrefix("LLIMIT_EVENT=") }.map(String.init)
    }

    var runner = attachMonitor()
    await daemon.refreshNow()
    await daemon.refreshNow()
    runner.waitUntilIdle()
    XCTAssertEqual(deliveredEvents(), ["LLIMIT_EVENT=failure"])

    // The restarted daemon remembers the delivered alert.
    runner = attachMonitor()
    await daemon.refreshNow()
    runner.waitUntilIdle()
    XCTAssertEqual(deliveredEvents(), ["LLIMIT_EVENT=failure"])

    client.error = nil
    await daemon.refreshNow()
    runner.waitUntilIdle()
    XCTAssertEqual(deliveredEvents(), ["LLIMIT_EVENT=failure", "LLIMIT_EVENT=recovered"])

    let hookOutput = try String(contentsOf: output, encoding: .utf8)
    let failureBlock = try XCTUnwrap(hookOutput.components(separatedBy: "---").first)
    XCTAssertTrue(failureBlock.contains("LLIMIT_FAILURE_KIND=auth"))
    // The account never fetched usage, so its configured name comes from settings.
    XCTAssertTrue(failureBlock.contains("LLIMIT_ACCOUNT_NAME=Claude Work"), failureBlock)
    XCTAssertFalse(hookOutput.contains(secret), "the hook payload leaked a credential")
    XCTAssertFalse(hookOutput.contains("rejected"), "the hook payload leaked a provider error message")

    let state = try String(contentsOf: paths.alertsStateFileURL, encoding: .utf8)
    XCTAssertFalse(state.contains(secret))
    XCTAssertFalse(state.contains("rejected"))
    let mode = try FileManager.default.attributesOfItem(atPath: paths.alertsStateFileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)
    XCTAssertEqual(paths.alertsStateFileURL.deletingLastPathComponent(), paths.snapshotFileURL.deletingLastPathComponent())
    XCTAssertEqual(paths.alertsStateFileURL.lastPathComponent, "alerts-state.json")
  }

  func testStateFileIsPrivateRegardlessOfUmaskAndReplacesTheOldOne() throws {
    let previousMask = umask(0)
    defer { umask(previousMask) }
    try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: paths.alertsStateFileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.alertsStateFileURL.path)

    var state = QuotaEventState()
    state.failureLatches = [.init(accountID: "a", kind: .auth)]
    let store = QuotaEventStateStore(fileURL: paths.alertsStateFileURL)
    try store.save(state)

    let mode = try FileManager.default.attributesOfItem(atPath: paths.alertsStateFileURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)
    XCTAssertEqual(try store.load(), state)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path), ["alerts-state.json"])
  }

  func testSlowHookDoesNotBlockTheRefresh() async throws {
    let runner = ChildProcessRunner(timeout: 2, log: log)
    let sink = EventHookSink(executable: try script("slow", "exec sleep 5"), runner: runner, inheritedEnvironment: ["PATH": "/usr/bin:/bin"])
    let monitor = QuotaAlertMonitor(stateFileURL: paths.alertsStateFileURL, config: .default, sinks: [sink], log: log)
    let client = ScriptedClient()
    client.error = ProviderClientError(kind: .auth, message: "expired")
    let daemon = QuotaDaemon(
      paths: paths,
      coordinator: QuotaCoordinator(clients: [client]),
      makeDiscovery: { CredentialDiscovery(homeDirectories: [self.tempDirectory]) },
      log: { _ in }
    )
    daemon.loadConfiguration()
    daemon.addAccount(provider: .anthropic, credentials: [CredentialField.anthropicAccessToken: "test-token"])
    daemon.onSnapshotSaved = { previous, current in monitor.process(previous: previous, current: current) }

    let start = Date()
    await daemon.refreshNow()

    XCTAssertLessThan(Date().timeIntervalSince(start), 1, "the refresh waited for the hook")
    XCTAssertTrue(loggedText.contains("Alert: Claude: sign-in needed"))
    runner.waitUntilIdle()
    XCTAssertTrue(loggedText.contains("slow did not finish within 2s"))
  }

  func testUnreadableStateStartsFresh() throws {
    try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: paths.alertsStateFileURL)
    let monitor = QuotaAlertMonitor(stateFileURL: paths.alertsStateFileURL, config: .default, sinks: [], log: log)
    let now = Date()
    let current = QuotaSnapshot(
      generatedAt: now,
      providers: [ProviderUsage(accountID: "a", provider: .anthropic, title: "Claude", metrics: [UsageMetric(id: "m", label: "Weekly", remainingPercent: 3)], fetchedAt: now)],
      failures: []
    )

    monitor.process(previous: nil, current: current, now: now)

    XCTAssertTrue(loggedText.contains("Alert state unreadable"))
    XCTAssertTrue(loggedText.contains("Alert: Claude: Weekly low"))
    XCTAssertNotNil(try QuotaEventStateStore(fileURL: paths.alertsStateFileURL).load())
  }
}

/// Fails with `error` while it is set, otherwise reports 80% remaining.
private final class ScriptedClient: QuotaProviderClient, @unchecked Sendable {
  let provider: QuotaProvider = .anthropic
  var error: ProviderClientError?

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    if let error {
      throw error
    }
    return ProviderUsage(
      accountID: configuration.accountID,
      provider: provider,
      title: configuration.displayName,
      metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 80)],
      fetchedAt: now
    )
  }
}
