import Foundation
import XCTest
@testable import QuotaCore

final class CodexRPCSessionTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testJSONValuesRoundTripWithoutCoercingBooleans() throws {
    let value: CodexRPCValue = .object([
      "items": .array([.string("hello\n世界"), .number(3.5), .bool(true), .null]),
      "nested": .object(["enabled": .bool(false)])
    ])
    XCTAssertEqual(try JSONDecoder().decode(CodexRPCValue.self, from: JSONEncoder().encode(value)), value)
    XCTAssertEqual(value["items"]?.arrayValue?.first?.stringValue, "hello\n世界")
    XCTAssertEqual(value["nested"]?["enabled"]?.boolValue, false)
    XCTAssertNil(value["missing"])
    XCTAssertNil(CodexRPCValue.bool(true).numberValue)
  }

  func testHandshakeLiteralArgumentsEnvironmentAndInterleavedMessages() async throws {
    let arguments = ["literal with spaces", "$(touch expanded)", "`touch backticks`", "; touch separated"]
    let session = try fixture("""
      printf '{"method":"account/updated","params":{"sequence":1}}\\n'
      printf '{"id":"%s","result":%s}\\n' "$request_id" "$frame"
      printf '{"method":"account/updated","params":{"sequence":2}}\\n'
      """, arguments: arguments)
    try await session.start()
    let result = try await session.request(method: "inspect", params: .object(["message": .string("hello\n世界")]))
    XCTAssertEqual(result["method"], .string("inspect"))
    XCTAssertEqual(result["params"]?["message"], .string("hello\n世界"))
    let first = try await session.nextNotification()
    let second = try await session.nextNotification()
    XCTAssertEqual(first, CodexRPCNotification(method: "account/updated", params: .object(["sequence": .number(1)])))
    XCTAssertEqual(second.params["sequence"], .number(2))
    let handshake = try JSONDecoder().decode(CodexRPCValue.self, from: Data(contentsOf: directory.appendingPathComponent("initialize.json")))
    XCTAssertEqual(handshake["params"]?["clientInfo"]?["name"], .string("llimit"))
    XCTAssertEqual(handshake["params"]?["clientInfo"]?["version"], .string("1"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("initialized.txt").path))
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("arguments.txt")), arguments.joined(separator: "\n") + "\n")
    let environment = try String(contentsOf: directory.appendingPathComponent("environment.txt")).split(separator: "\n").map(String.init)
    XCTAssertEqual(environment.first, "isolated-profile")
    XCTAssertEqual(URL(fileURLWithPath: environment[1]).resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
    for name in ["expanded", "backticks", "separated"] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
    try await waitUntilIdle(session)
    try await session.close()
    let exited = await session.hasExited
    XCTAssertTrue(exited)
    try await session.close()
  }

  func testConcurrentRequestsMatchResponsesByIDWhenRepliesArriveOutOfOrder() async throws {
    let session = try fixture(#"""
      first_id="$request_id"
      first_frame="$frame"
      IFS= read -r second_frame
      second_id=$(printf '%s' "$second_frame" | sed -n 's/.*"id":"\([^" ]*\)".*/\1/p')
      printf '{"id":"%s","result":%s}\n' "$second_id" "$second_frame"
      printf '{"id":"%s","result":%s}\n' "$first_id" "$first_frame"
      """#)
    try await session.start()
    async let first = session.request(method: "first")
    async let second = session.request(method: "second")
    let responses = try await (first, second)
    XCTAssertEqual(responses.0["method"], .string("first"))
    XCTAssertEqual(responses.1["method"], .string("second"))
    try await waitUntilIdle(session)
    try await session.close()
  }

  func testTimedOutRequestRemainsBusyUntilLateResponse() async throws {
    let session = try fixture("""
      sleep 0.2
      printf completed > completed.txt
      printf '{"id":"%s","result":{"finished":true}}\\n' "$request_id"
      """)
    try await session.start()
    do {
      _ = try await session.request(method: "refresh", timeout: 0.01)
      XCTFail("Expected bounded timeout")
    } catch { XCTAssertEqual(error as? CodexRPCError, .timedOut) }
    let pending = await session.pendingRequestCount
    XCTAssertEqual(pending, 1)
    do { try await session.close(); XCTFail("Must not close beneath a rotation") }
    catch { XCTAssertEqual(error as? CodexRPCError, .busy) }
    try await waitUntilIdle(session)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed.txt").path))
    try await session.close()
  }

  func testCancellingWaitKeepsRequestTracked() async throws {
    let session = try fixture("""
      printf started > started.txt
      sleep 0.2
      printf '{"id":"%s","result":null}\\n' "$request_id"
      """)
    try await session.start()
    let waiter = Task { try await session.request(method: "refresh") }
    try await waitForFile("started.txt")
    waiter.cancel()
    do { _ = try await waiter.value; XCTFail("Expected cancelled wait") }
    catch { XCTAssertEqual(error as? CodexRPCError, .cancelled) }
    let pending = await session.pendingRequestCount
    XCTAssertEqual(pending, 1)
    try await waitUntilIdle(session)
    try await session.close()
  }

  func testEOFReturnsSanitizedErrorAndDrainsLastResponseBeforeExit() async throws {
    let complete = try fixture("""
      printf '{"id":"%s","result":"last-response"}\\n' "$request_id"
      exit 0
      """)
    try await complete.start()
    let value = try await complete.request(method: "finish")
    XCTAssertEqual(value, .string("last-response"))
    try await waitForExit(complete)
    try await complete.close()

    let abrupt = try fixture("""
      printf 'private-provider-error' >&2
      exit 9
      """)
    try await abrupt.start()
    do { _ = try await abrupt.request(method: "finish"); XCTFail("Expected EOF error") }
    catch {
      XCTAssertEqual(error as? CodexRPCError, .sessionClosed)
      XCTAssertFalse(error.localizedDescription.contains("private-provider-error"))
    }
    try await waitForExit(abrupt)
    let pending = await abrupt.pendingRequestCount
    XCTAssertEqual(pending, 0)
    try await abrupt.close()
  }

  func testMalformedFrameFailsWaitWithoutForgettingLiveRequest() async throws {
    let session = try fixture("""
      printf 'not-json-private-secret\\n'
      sleep 0.2
      printf '{"id":"%s","result":null}\\n' "$request_id"
      """)
    try await session.start()
    do { _ = try await session.request(method: "refresh"); XCTFail("Expected protocol error") }
    catch {
      XCTAssertEqual(error as? CodexRPCError, .malformedMessage)
      XCTAssertFalse(error.localizedDescription.contains("private-secret"))
    }
    let pending = await session.pendingRequestCount
    XCTAssertEqual(pending, 1)
    try await waitUntilIdle(session)
    try await session.close()
  }

  func testServerErrorDoesNotExposePayloadAndUnsupportedRequestsAreRejected() async throws {
    let session = try fixture("""
      printf '{"id":7,"method":"account/chatgptAuthTokens/refresh","params":{"secret":"private-token"}}\\n'
      IFS= read -r server_reply
      printf '%s' "$server_reply" > server-reply.json
      printf '{"id":"%s","error":{"code":-1,"message":"private-token"}}\\n' "$request_id"
      """)
    try await session.start()
    do { _ = try await session.request(method: "fail"); XCTFail("Expected server error") }
    catch {
      XCTAssertEqual(error as? CodexRPCError, .serverRejected)
      XCTAssertFalse(error.localizedDescription.contains("private-token"))
    }
    let reply = try JSONDecoder().decode(CodexRPCValue.self, from: Data(contentsOf: directory.appendingPathComponent("server-reply.json")))
    XCTAssertEqual(reply["id"], .number(7))
    XCTAssertEqual(reply["error"]?["code"], .number(-32601))
    XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("server-reply.json")).contains("private-token"))
    try await waitUntilIdle(session)
    try await session.close()
  }

  func testNotificationOverflowFailsInsteadOfLosingLoginCompletion() async throws {
    let session = try fixture("""
      count=0
      while [ "$count" -lt 129 ]; do
        printf '{"method":"account/updated","params":{}}\\n'
        count=$((count + 1))
      done
      printf '{"id":"%s","result":null}\\n' "$request_id"
      """)
    try await session.start()
    do { _ = try await session.request(method: "overflow"); XCTFail("Expected bounded queue error") }
    catch { XCTAssertEqual(error as? CodexRPCError, .notificationOverflow) }
    try await waitUntilIdle(session)
    try await session.close()
  }

  func testOversizedFrameIsBoundedAndLateResponseStillReleasesBusyState() async throws {
    let session = try fixture("""
      awk 'BEGIN { for (i = 0; i < 1048600; i++) printf "a"; printf "\\n"; }'
      printf '{"id":"%s","result":null}\\n' "$request_id"
      """)
    try await session.start()
    do { _ = try await session.request(method: "oversized"); XCTFail("Expected frame size error") }
    catch { XCTAssertEqual(error as? CodexRPCError, .messageTooLarge) }
    try await waitUntilIdle(session)
    try await session.close()
  }

  func testNotificationTimeoutAndCancellationDoNotAffectNextWaiter() async throws {
    let session = try fixture("""
      printf '{"method":"ready","params":null}\\n'
      printf '{"id":"%s","result":null}\\n' "$request_id"
      """)
    try await session.start()
    do { _ = try await session.nextNotification(timeout: 0.01); XCTFail("Expected timeout") }
    catch { XCTAssertEqual(error as? CodexRPCError, .timedOut) }
    let waiter = Task { try await session.nextNotification() }
    waiter.cancel()
    do { _ = try await waiter.value; XCTFail("Expected cancellation") }
    catch { XCTAssertEqual(error as? CodexRPCError, .cancelled) }
    _ = try await session.request(method: "notify")
    let notification = try await session.nextNotification()
    XCTAssertEqual(notification.method, "ready")
    let closingWaiter = Task { try await session.nextNotification() }
    try await waitUntilIdle(session)
    try await session.close()
    do { _ = try await closingWaiter.value; XCTFail("Expected closed connection") }
    catch { XCTAssertEqual(error as? CodexRPCError, .sessionClosed) }
  }

  func testLaunchAndInitializationFailuresRemainClosable() async throws {
    let missing = CodexRPCSession(executable: directory.appendingPathComponent("missing"), arguments: [], environment: [:], workingDirectory: directory)
    do { try await missing.start(); XCTFail("Expected launch error") }
    catch { XCTAssertEqual(error as? CodexRPCError, .launchFailed) }
    let exited = await missing.hasExited
    XCTAssertTrue(exited)
    try await missing.close()

    let rejected = try fixture("", initialization: "printf '{\"id\":\"%s\",\"error\":{\"code\":-1,\"message\":\"private-secret\"}}\\n' \"$request_id\"")
    do { try await rejected.start(); XCTFail("Expected initialization error") }
    catch { XCTAssertEqual(error as? CodexRPCError, .serverRejected) }
    try await waitUntilIdle(rejected)
    try await rejected.close()
  }

  func testCloseImmediatelyAfterHandshakeDrainsInitializationNotification() async throws {
    let session = try fixture("")
    try await session.start()
    try await session.close()
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("initialized.txt").path))
    let exited = await session.hasExited
    XCTAssertTrue(exited)
  }

  func testGracefulCloseTimeoutRetainsChildUntilActualExit() async throws {
    let session = try fixture("", afterInputCloses: "sleep 0.2\nprintf completed > completed.txt")
    try await session.start()
    try await waitUntilIdle(session)
    do { try await session.close(timeout: 0.01); XCTFail("Expected bounded close timeout") }
    catch { XCTAssertEqual(error as? CodexRPCError, .timedOut) }
    let exitedEarly = await session.hasExited
    XCTAssertFalse(exitedEarly)
    try await waitForExit(session)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed.txt").path))
    try await session.close()
  }

  func testEarlyChildExitCannotExposeWriteErrorsOrCrashHost() async throws {
    let initialization = "printf '{\"id\":\"%s\",\"result\":null}\\n' \"$request_id\"\nexit 0"
    let session = try fixture("", initialization: initialization)
    do {
      try await session.start()
      _ = try await session.request(method: "after-exit")
      XCTFail("Expected closed connection")
    } catch {
      XCTAssertTrue(error is CodexRPCError)
    }
    try await waitForExit(session)
    try await waitUntilIdle(session)
    try await session.close()
  }

  private func fixture(_ body: String, arguments: [String] = [], initialization: String? = nil, afterInputCloses: String = "") throws -> CodexRPCSession {
    let executable = directory.appendingPathComponent("fixture-cli")
    let initialization = initialization ?? "printf '{\"id\":\"%s\",\"result\":{\"userAgent\":\"fixture\"}}\\n' \"$request_id\""
    let script = #"""
      #!/bin/sh
      printf '%s\n' "$@" > arguments.txt
      printf '%s\n%s\n' "$SYNTHETIC_ENV" "$PWD" > environment.txt
      [ -c /dev/stderr ] || exit 31
      while IFS= read -r frame; do
        request_id=$(printf '%s' "$frame" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        case "$frame" in
          *'"method":"initialize"'*)
            printf '%s' "$frame" > initialize.json
            \#(initialization)
            ;;
          *'"method":"initialized"'*)
            printf ready > initialized.txt
            ;;
          *)
            \#(body)
            ;;
        esac
      done
      \#(afterInputCloses)
      """#
    try (script + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return CodexRPCSession(executable: executable, arguments: arguments, environment: ["PATH": "/usr/bin:/bin", "SYNTHETIC_ENV": "isolated-profile"], workingDirectory: directory)
  }

  private func waitUntilIdle(_ session: CodexRPCSession) async throws {
    let deadline = Date().addingTimeInterval(5)
    while await session.isBusy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let busy = await session.isBusy
    XCTAssertFalse(busy, "Fixture did not finish its operation")
  }

  private func waitForExit(_ session: CodexRPCSession) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await session.hasExited), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let exited = await session.hasExited
    XCTAssertTrue(exited, "Fixture did not exit")
  }

  private func waitForFile(_ name: String) async throws {
    let path = directory.appendingPathComponent(name).path
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: path), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }
}
