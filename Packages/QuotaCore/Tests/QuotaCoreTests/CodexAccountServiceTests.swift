import Foundation
import XCTest
@testable import QuotaCore

final class CodexAccountServiceTests: XCTestCase {
  private var temporary: URL!
  private var store: CodexProfileStore!
  private var executable: URL!

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    store = CodexProfileStore(root: temporary.appendingPathComponent("profiles"))
    executable = temporary.appendingPathComponent("fake-codex")
    try Self.fixture.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

  func testLoginConfirmsIdentityAndReleasesProfileAfterGracefulExit() async throws {
    let profile = try prepare()
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    XCTAssertEqual(login.authURL.host, "auth.openai.com")
    XCTAssertTrue(store.hasPendingOperation(profile))
    let identity = try await service.finishLogin(login)
    XCTAssertEqual(identity.accountID, "workspace-one")
    XCTAssertEqual(identity.userID, "user-one")
    XCTAssertFalse(store.hasPendingOperation(profile))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: profile).appendingPathComponent("work/exited").path))
    let requests = try requestLog(profile)
    XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/login/start", "account/read"])
    XCTAssertEqual((requests.last?["params"] as? [String: Any])?["refreshToken"] as? Bool, false)
  }

  func testQuotaRefreshesCredentialsBeforeReadingRatesAndChecksIdentity() async throws {
    let profile = try prepare()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let service = makeService()
    let usage = try await service.fetchUsage(configuration: configuration(profile), now: now)
    XCTAssertEqual(usage.fetchedAt, now)
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 63)
    XCTAssertFalse(store.hasPendingOperation(profile))
    let requests = try requestLog(profile)
    XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/read", "account/rateLimits/read"])
    XCTAssertEqual((requests[2]["params"] as? [String: Any])?["refreshToken"] as? Bool, true)
  }

  func testLoginWaitsForAccountStateAfterBrowserCompletion() async throws {
    let profile = try prepare(mode: "delayed-account-update")
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    let identity = try await service.finishLogin(login)
    XCTAssertEqual(identity.userID, "user-one")
    XCTAssertFalse(store.hasPendingOperation(profile))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: profile).appendingPathComponent("work/read-before-ready").path))
  }

  func testLoginAcceptsAccountUpdateBeforeMatchingCompletion() async throws {
    let profile = try prepare(mode: "account-update-first")
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    let identity = try await service.finishLogin(login)
    XCTAssertEqual(identity.accountID, "workspace-one")
    XCTAssertFalse(store.hasPendingOperation(profile))
  }

  func testAccountUpdateCannotOverrideFailedLoginCompletion() async throws {
    let profile = try prepare(mode: "failed-login")
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    do { _ = try await service.finishLogin(login); XCTFail("Failed login must not be accepted") }
    catch { XCTAssertEqual(error as? CodexConnectionError, .signInFailed) }
    XCTAssertFalse(store.hasPendingOperation(profile))
    XCTAssertFalse(try requestLog(profile).contains { $0["method"] as? String == "account/read" })
  }

  func testInheritedCredentialsAndConfigurationCannotReachProfileProcess() async throws {
    let profile = try prepare()
    let service = makeService(environment: [
      "PATH": "/usr/bin:/bin", "HOME": "/synthetic-home", "LANG": "C",
      "CODEX_HOME": "/wrong-profile", "OPENAI_API_KEY": "fake-global-key",
      "OPENAI_BASE_URL": "https://example.invalid", "CODEX_AUTH_JSON": "fake-global-auth",
      "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "wrong", "NODE_OPTIONS": "--bad", "BASH_ENV": "/bad"
    ])
    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    let path = store.directory(for: profile).appendingPathComponent("work/environment.json")
    let environment = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: String])
    XCTAssertEqual(environment["CODEX_HOME"], store.directory(for: profile).path)
    XCTAssertEqual(environment["HOME"], "/synthetic-home")
    for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_AUTH_JSON", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "NODE_OPTIONS", "BASH_ENV"] {
      XCTAssertNil(environment[key])
    }
    let arguments = try String(contentsOf: store.directory(for: profile).appendingPathComponent("work/arguments.json"), encoding: .utf8)
    XCTAssertTrue(arguments.contains("cli_auth_credentials_store=\\\"file\\\""))
    XCTAssertTrue(arguments.contains("forced_login_method=\\\"chatgpt\\\""))
  }

  func testPendingRecordPreventsLaunchAndRemoval() async throws {
    let profile = try prepare()
    try store.acquire(profile)
    let service = makeService()
    do { _ = try await service.beginLogin(profile: profile); XCTFail("Pending grant must not be replayed") }
    catch { XCTAssertTrue(error is CodexConnectionError) }
    let removed = await service.remove(profile)
    XCTAssertFalse(removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: profile).appendingPathComponent("work/requests.jsonl").path))
    XCTAssertTrue(store.hasPendingOperation(profile))
  }

  func testSecondLoginCannotCloseTheFirstCallersSession() async throws {
    let profile = try prepare()
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    do { _ = try await service.beginLogin(profile: profile); XCTFail("An active profile must reject another caller") }
    catch { XCTAssertTrue(error is CodexConnectionError) }
    XCTAssertTrue(store.hasPendingOperation(profile))
    let identity = try await service.finishLogin(login)
    XCTAssertEqual(identity.accountID, "workspace-one")
    XCTAssertFalse(store.hasPendingOperation(profile))
  }

  func testMismatchedFetchDoesNotCloseAnExistingLoginSession() async throws {
    let profile = try prepare()
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    let wrong = configuration(profile, identity: CodexAccountIdentity(accountID: "different", userID: "user-one"))
    do { _ = try await service.fetchUsage(configuration: wrong, now: Date()); XCTFail("Wrong identity must fail") }
    catch { XCTAssertTrue(error is ProviderClientError) }
    XCTAssertTrue(store.hasPendingOperation(profile))
    _ = try await service.finishLogin(login)
  }

  func testCancellationReleasesMarkerEvenWhenFinishIsWaiting() async throws {
    let profile = try prepare(mode: "wait-login")
    let service = makeService()
    let login = try await service.beginLogin(profile: profile)
    let finish = Task { try await service.finishLogin(login) }
    await service.cancelLogin(login)
    do { _ = try await finish.value; XCTFail("Canceled login must not succeed") }
    catch { XCTAssertTrue(error is CodexConnectionError) }
    XCTAssertFalse(store.hasPendingOperation(profile))
    let removed = await service.remove(profile)
    XCTAssertTrue(removed)
  }

  func testChangedIdentityAfterRenewalDoesNotPublishUsage() async throws {
    let profile = try prepare(mode: "change-identity")
    let service = makeService()
    do { _ = try await service.fetchUsage(configuration: configuration(profile), now: Date()); XCTFail("Changed identity must fail") }
    catch { XCTAssertTrue(error is ProviderClientError) }
    XCTAssertFalse(store.hasPendingOperation(profile))
    XCTAssertFalse(try requestLog(profile).contains { $0["method"] as? String == "account/rateLimits/read" })
  }

  func testStaleLoginHandleCannotCancelANewerSession() async throws {
    let profile = try prepare()
    let service = makeService()
    let first = try await service.beginLogin(profile: profile)
    _ = try await service.finishLogin(first)
    let second = try await service.beginLogin(profile: profile)
    await service.cancelLogin(first)
    XCTAssertTrue(store.hasPendingOperation(profile))
    _ = try await service.finishLogin(second)
    XCTAssertFalse(store.hasPendingOperation(profile))
  }

  func testCancelledRenewalRetainsMarkerUntilReplyAndGracefulExit() async throws {
    let profile = try prepare(mode: "slow-read")
    let service = makeService()
    let configuration = configuration(profile)
    let operation = Task { try await service.fetchUsage(configuration: configuration, now: Date()) }
    let signal = store.directory(for: profile).appendingPathComponent("work/read-started")
    try await waitUntil { FileManager.default.fileExists(atPath: signal.path) }
    operation.cancel()
    do { _ = try await operation.value; XCTFail("Canceled wait must not publish usage") }
    catch { XCTAssertTrue(error is ProviderClientError) }
    XCTAssertTrue(store.hasPendingOperation(profile))
    let removedDuringRenewal = await service.remove(profile)
    XCTAssertFalse(removedDuringRenewal)
    try await waitUntil { !self.store.hasPendingOperation(profile) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: profile).appendingPathComponent("work/exited").path))
    XCTAssertEqual(try requestLog(profile).filter { $0["method"] as? String == "account/read" }.count, 1)
  }

  func testProfileEnvironmentKeepsProxyAndCertificateSettings() {
    let network = [
      "HTTPS_PROXY": "http://proxy.example.invalid:8080", "https_proxy": "http://lower.example.invalid:8080",
      "HTTP_PROXY": "http://proxy.example.invalid:8080", "http_proxy": "http://lower.example.invalid:8080",
      "NO_PROXY": "localhost", "no_proxy": "localhost", "ALL_PROXY": "http://all.example.invalid:8080",
      "all_proxy": "http://all.example.invalid:8080", "NODE_EXTRA_CA_CERTS": "/etc/corporate/ca.pem",
      "SSL_CERT_FILE": "/etc/corporate/bundle.pem", "SSL_CERT_DIR": "/etc/corporate/certs",
      "CODEX_CA_CERTIFICATE": "/etc/corporate/codex.pem"
    ]
    let directory = temporary.appendingPathComponent("profile")
    let executable = temporary.appendingPathComponent("bin/codex")
    let environment = CodexAccountService.environment(
      parent: network.merging(["OPENAI_API_KEY": "fake-global-key", "REQUESTS_CA_BUNDLE": "/etc/python.pem"]) { $1 },
      directory: directory, executable: executable)
    for (key, value) in network { XCTAssertEqual(environment[key], value, key) }
    XCTAssertNil(environment["OPENAI_API_KEY"])
    XCTAssertNil(environment["REQUESTS_CA_BUNDLE"])
    XCTAssertEqual(environment["CODEX_HOME"], directory.path)
    XCTAssertEqual(environment["PATH"]?.split(separator: ":").first.map(String.init), executable.deletingLastPathComponent().path)
  }

  func testVersionGateRequiresTestedOfficialCLIAndOrdersPrereleases() {
    let supported = [
      "codex-cli 0.144.4\n", "codex-cli 0.145.0", "codex-cli 1.0.0", "codex-cli 0.150.0-alpha.2",
      "codex-cli 0.144.4+build.7", "codex-cli 0.145.0-rc.1+abc.5", "codex-cli 0.144.5-0"
    ]
    for output in supported {
      XCTAssertTrue(isSupported(output), output)
    }
    // A prerelease of the minimum precedes that release, so it stays too old.
    let unsupported = [
      "0.1.0", "codex 0.144.4", "codex-cli 0.144.3", "codex-cli 0.1.0", "codex-cli 0.144.4-beta",
      "codex-cli 0.144.3+build.9", "codex-cli 999999999999999999999999.0.0", "codex-cli 0.144.4\nadditional output",
      "codex-cli 0.144.4-", "codex-cli 0.144.4+", "codex-cli 0.150.0-alpha..2", "codex-cli 0.150.0-al_pha",
      "codex-cli 0.150", "codex-cli v0.150.0", "codex-cli 0.150.0.1"
    ]
    for output in unsupported {
      XCTAssertFalse(isSupported(output), output)
    }
  }

  func testVersionPrecedenceFollowsSemanticVersioning() throws {
    let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                   "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1-0", "1.0.1", "1.10.0"]
    let versions = try ordered.map { try XCTUnwrap(CodexCLIVersion(versionOutput: "codex-cli " + $0), $0) }
    for (lower, higher) in zip(versions, versions.dropFirst()) {
      XCTAssertLessThan(lower, higher, "\(lower) < \(higher)")
      XCTAssertFalse(higher < lower, "\(higher) < \(lower)")
    }
    XCTAssertEqual(versions.map(\.description), ordered)
    XCTAssertEqual(CodexCLIVersion(versionOutput: "codex-cli 0.150.0-alpha.2+build.1"),
                   CodexCLIVersion(versionOutput: "codex-cli 0.150.0-alpha.2+build.9"))
  }

  func testVersionProbeReportsWhyNoCandidateIsUsable() async throws {
    let missing = temporary.appendingPathComponent("missing-codex")
    await assertProbeError([missing], .cliNotFound)

    let failing = try versionFixture("failing", body: "exit 127")
    let old = try versionFixture("old", body: "printf 'codex-cli 0.140.0-beta.1\\n'")
    let unrelated = try versionFixture("unrelated", body: "printf 'usage: something else\\n'")
    // Missing candidates are skipped; the first install that exists is the one
    // LLimit would use, so its problem is the one the user needs to fix.
    await assertProbeError([missing, failing, old], .cliFailed(path: failing.path, .exit(127)))
    await assertProbeError([old, failing], .cliTooOld(path: old.path, version: "0.140.0-beta.1"))
    await assertProbeError([unrelated], .cliFailed(path: unrelated.path, .unrecognizedVersion))

    let message = CodexConnectionError.cliFailed(path: failing.path, .exit(127)).localizedDescription
    XCTAssertTrue(message.contains(failing.path), message)
    XCTAssertTrue(message.contains("exit 127"), message)
    XCTAssertTrue(message.contains("Reinstall"), message)
    let timeout = CodexConnectionError.cliFailed(path: failing.path, .timeout).localizedDescription
    XCTAssertTrue(timeout.contains("again in a moment"), timeout)
    XCTAssertFalse(timeout.contains("Reinstall"), timeout)
    XCTAssertTrue(CodexConnectionError.cliTooOld(path: old.path, version: "0.140.0").localizedDescription.contains("0.144.4"))
  }

  func testVersionProbeStopsExcessiveOutput() async throws {
    let chatty = try versionFixture("chatty", body: "yes | head -c \(CodexCLIProbe.outputLimit + 1)")
    await assertProbeError([chatty], .cliFailed(path: chatty.path, .excessiveOutput))
  }

  func testVersionProbeTimeoutKillsTheChildAndItsDescendants() async throws {
    // The write happens in a background subshell, so killing only the direct
    // child would leave it running.
    let stuck = try versionFixture("stuck", body: #"( sleep 1; printf survived > "$(dirname "$0")/survived" ) & wait"#)
    await assertProbeError([stuck], .cliFailed(path: stuck.path, .timeout), timeout: 0.2)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("survived").path))
  }

  func testNpmShimStartsSessionWhenInterpreterIsOnlyBesideIt() async throws {
    let bin = temporary.appendingPathComponent("node-prefix/bin", isDirectory: true)
    let shim = try discoverableFixture(in: bin)
    let profile = try prepare()
    let service = CodexAccountService(root: store.root, executable: nil, candidates: [shim],
                                      environment: ["PATH": "/usr/bin:/bin", "HOME": temporary.path])
    let usage = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 63)
    let path = store.directory(for: profile).appendingPathComponent("work/environment.json")
    let environment = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: String])
    XCTAssertEqual(environment["PATH"]?.split(separator: ":").first.map(String.init), bin.path)
  }

  func testVersionProbeRunsOnceUntilTheExecutableChanges() async throws {
    let shim = try discoverableFixture(in: temporary.appendingPathComponent("node-prefix/bin", isDirectory: true))
    let profile = try prepare()
    let service = CodexAccountService(root: store.root, executable: nil, candidates: [shim],
                                      environment: ["PATH": "/usr/bin:/bin", "HOME": temporary.path])
    let probes = shim.deletingLastPathComponent().appendingPathComponent("version-probes")
    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    XCTAssertEqual(try String(contentsOf: probes, encoding: .utf8).split(separator: "\n").count, 1)

    let handle = try FileHandle(forWritingTo: shim)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("# updated install\n".utf8))
    try handle.close()
    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    XCTAssertEqual(try String(contentsOf: probes, encoding: .utf8).split(separator: "\n").count, 2)
  }

  func testOnlyStartupFailuresThatImplicateTheExecutableProbeAgain() async throws {
    let shim = try discoverableFixture(in: temporary.appendingPathComponent("node-prefix/bin", isDirectory: true))
    let profile = try prepare()
    let mode = store.directory(for: profile).appendingPathComponent("work/mode")
    let service = CodexAccountService(root: store.root, executable: nil, candidates: [shim],
                                      environment: ["PATH": "/usr/bin:/bin", "HOME": temporary.path])
    let probes = shim.deletingLastPathComponent().appendingPathComponent("version-probes")
    func probeCount() throws -> Int { try String(contentsOf: probes, encoding: .utf8).split(separator: "\n").count }

    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    try "reject-initialize".write(to: mode, atomically: true, encoding: .utf8)
    do { _ = try await service.fetchUsage(configuration: configuration(profile), now: Date()); XCTFail("Rejected startup must fail") }
    catch { XCTAssertTrue(error is ProviderClientError, "Unexpected error: \(error)") }
    try await waitUntil { !self.store.hasPendingOperation(profile) }
    try "normal".write(to: mode, atomically: true, encoding: .utf8)
    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    XCTAssertEqual(try probeCount(), 1)

    try "exit-on-start".write(to: mode, atomically: true, encoding: .utf8)
    do { _ = try await service.fetchUsage(configuration: configuration(profile), now: Date()); XCTFail("Exited child must fail") }
    catch { XCTAssertTrue(error is ProviderClientError, "Unexpected error: \(error)") }
    try await waitUntil { !self.store.hasPendingOperation(profile) }
    try "normal".write(to: mode, atomically: true, encoding: .utf8)
    _ = try await service.fetchUsage(configuration: configuration(profile), now: Date())
    XCTAssertEqual(try probeCount(), 2)
  }

  func testVersionProbeRunsNpmShimWhoseInterpreterIsBesideIt() async throws {
    // npm installs `#!/usr/bin/env node` shims beside node, a directory that a
    // Finder-launched app's PATH does not contain.
    let bin = temporary.appendingPathComponent("node-prefix/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let interpreter = bin.appendingPathComponent("fakenode")
    try "#!/bin/sh\nexec /bin/sh \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
    let shim = bin.appendingPathComponent("codex")
    try "#!/usr/bin/env fakenode\nprintf 'codex-cli 0.144.4\\n'\n".write(to: shim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)

    let discovered = try await CodexCLIProbe.firstSupported([shim], environment: [
      "PATH": "/usr/bin:/bin", "HOME": temporary.path
    ])
    XCTAssertEqual(discovered, shim)
  }

  func testVersionProbeSkipsLegacyExecutableAndRunsWithoutUserAuthentication() async throws {
    let old = try versionFixture("old", body: "printf 'codex-cli 0.1.0\\n'")
    let supported = try versionFixture("new", body: #"""
      [ "$1" = '--version' ] && [ "$#" -eq 1 ] || exit 7
      [ "$HOME" = "$CODEX_HOME" ] && [ "$HOME" != '/ordinary-home' ] || exit 8
      [ "$VOLTA_HOME" = '/ordinary-home/.volta' ] || exit 10
      [ -z "${OPENAI_API_KEY+x}" ] && [ -z "${BASH_ENV+x}" ] || exit 9
      printf 'codex-cli 0.144.4\n'
      """#)
    let discovered = try await CodexCLIProbe.firstSupported([old, supported], environment: [
      "HOME": "/ordinary-home", "CODEX_HOME": "/ordinary-codex", "OPENAI_API_KEY": "fake-key", "BASH_ENV": "/untrusted", "PATH": "/usr/bin:/bin"
    ])
    XCTAssertEqual(discovered, supported)
  }

  func testVersionProbeTimeoutContinuesToNextExecutable() async throws {
    let stuck = try versionFixture("stuck", body: "exec /bin/sleep 5")
    let supported = try versionFixture("new", body: "printf 'codex-cli 0.144.4\\n'")
    let started = Date()
    let discovered = try await CodexCLIProbe.firstSupported([stuck, supported], environment: [:], timeout: 0.5)
    XCTAssertEqual(discovered, supported)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  private func isSupported(_ output: String) -> Bool {
    CodexCLIVersion(versionOutput: output).map { $0 >= CodexCLIProbe.minimumVersion } ?? false
  }

  private func assertProbeError(_ candidates: [URL], _ expected: CodexConnectionError, timeout: TimeInterval = 2,
                                file: StaticString = #filePath, line: UInt = #line) async {
    do {
      let found = try await CodexCLIProbe.firstSupported(candidates, environment: ["PATH": "/usr/bin:/bin"], timeout: timeout)
      XCTFail("Unexpectedly selected \(found.path)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? CodexConnectionError, expected, file: file, line: line)
    }
  }

  /// The app-server fixture as an npm-style shim: `#!/usr/bin/env fakenode`
  /// with the interpreter only in its own directory. Each probe is counted.
  private func discoverableFixture(in bin: URL) throws -> URL {
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let interpreter = bin.appendingPathComponent("fakenode")
    try "#!/bin/sh\nexec python3 \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
    let shim = bin.appendingPathComponent("codex")
    let script = Self.fixture.replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/env fakenode")
    try script.write(to: shim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
    return shim
  }

  private func versionFixture(_ name: String, body: String) throws -> URL {
    let executable = temporary.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(6)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), "Fixture did not reach the expected state")
  }

  private func prepare(mode: String = "normal") throws -> CodexAccountProfile {
    let profile = CodexAccountProfile()
    let directory = try store.prepare(profile)
    try codexTestAuthentication().write(to: directory.appendingPathComponent("auth.json"))
    try mode.write(to: directory.appendingPathComponent("work/mode"), atomically: true, encoding: .utf8)
    try codexTestAuthentication(accountID: "different").write(to: directory.appendingPathComponent("work/different-auth.json"))
    return profile
  }

  private func makeService(environment: [String: String] = ["PATH": "/usr/bin:/bin"]) -> CodexAccountService {
    CodexAccountService(root: store.root, executable: executable, environment: environment)
  }

  private func configuration(_ profile: CodexAccountProfile, identity: CodexAccountIdentity = CodexAccountIdentity(accountID: "workspace-one", userID: "user-one")) -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true, credentials: profile.credentials(identity: identity))
  }

  private func requestLog(_ profile: CodexAccountProfile) throws -> [[String: Any]] {
    let data = try String(contentsOf: store.directory(for: profile).appendingPathComponent("work/requests.jsonl"), encoding: .utf8)
    return try data.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
  }

  private static let fixture = #"""
    #!/usr/bin/env python3
    import json, os, pathlib, sys, threading, time
    if sys.argv[1:] == ['--version']:
        with open(pathlib.Path(__file__).with_name('version-probes'), 'a') as log:
            log.write('probe\n')
        print('codex-cli 0.144.4')
        sys.exit(0)
    root = pathlib.Path(os.environ['CODEX_HOME'])
    mode = pathlib.Path('mode').read_text()
    if mode == 'exit-on-start':
        sys.exit(3)
    pathlib.Path('environment.json').write_text(json.dumps(dict(os.environ)))
    pathlib.Path('arguments.json').write_text(json.dumps(sys.argv[1:]))
    def send(value):
        print(json.dumps(value), flush=True)
    account_ready = mode != 'delayed-account-update'
    def update_account():
        global account_ready
        if mode == 'delayed-account-update':
            time.sleep(0.5)
        account_ready = True
        send({'method': 'account/updated', 'params': {'authMode': 'chatgpt', 'planType': 'plus'}})
    for line in sys.stdin:
        request = json.loads(line)
        with open('requests.jsonl', 'a') as log:
            log.write(json.dumps(request) + '\n')
        method = request['method']
        if 'id' not in request:
            continue
        if mode == 'reject-initialize' and method == 'initialize':
            send({'id': request['id'], 'error': {'code': -32000, 'message': 'rejected'}})
            continue
        result = {}
        if method == 'account/login/start':
            result = {'loginId': 'test-login', 'authUrl': 'https://auth.openai.com/authorize?synthetic=1'}
        elif method == 'account/read':
            if mode == 'slow-read':
                pathlib.Path('read-started').write_text('started')
                time.sleep(0.5)
            if mode == 'change-identity':
                (root / 'auth.json').write_bytes(pathlib.Path('different-auth.json').read_bytes())
            result = {'account': {'type': 'chatgpt', 'email': 'test@example.invalid', 'planType': 'plus'}}
            if not account_ready:
                pathlib.Path('read-before-ready').write_text('early read')
                result = {'account': None, 'requiresOpenaiAuth': True}
        elif method == 'account/rateLimits/read':
            result = {'rateLimits': {'primary': {'usedPercent': 37, 'windowDurationMins': 300, 'resetsAt': 1800001000}, 'planType': 'plus'}}
        send({'id': request['id'], 'result': result})
        if method == 'account/login/start' and mode != 'wait-login':
            if mode in ('account-update-first', 'failed-login'):
                update_account()
            send({'method': 'account/login/completed', 'params': {'loginId': 'unrelated', 'success': True}})
            send({'method': 'account/login/completed', 'params': {'loginId': 'test-login', 'success': mode != 'failed-login'}})
            if mode not in ('account-update-first', 'failed-login'):
                threading.Thread(target=update_account, daemon=True).start()
    pathlib.Path('exited').write_text('graceful')
    """#
}
