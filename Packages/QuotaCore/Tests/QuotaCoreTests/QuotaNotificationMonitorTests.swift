import XCTest
@testable import QuotaCore

final class QuotaNotificationMonitorTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func reading(_ percent: Int, accounts: [String] = ["a"], at date: Date) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, providers: accounts.map {
      ProviderUsage(accountID: $0, provider: .anthropic, title: $0,
                    metrics: [UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: percent,
                                          resetAt: date.addingTimeInterval(3_600))], fetchedAt: date)
    }, failures: [])
  }

  @MainActor
  func testInterleavedAuthorizationDoesNotDuplicateOrOverwriteNewerState() async {
    let transport = Transport()
    let gate = Gate()
    transport.authorizationGate = gate
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    let first = reading(18, at: t0)
    monitor.submit(previous: nil, current: first, now: t0)
    await gate.waitUntilBlocked()

    monitor.submit(previous: first, current: reading(18, accounts: ["a", "b"], at: t0 + 900), now: t0 + 900)
    gate.release()
    await monitor.waitUntilIdle()

    XCTAssertEqual(transport.delivered.map(\.accountID), ["a", "b"])
    XCTAssertEqual(Set(store.state.thresholdLatches.map(\.accountID)), ["a", "b"])
  }

  @MainActor
  func testInterleavedDeliveryAndDisableCannotRestoreSuppression() async {
    let transport = Transport()
    let gate = Gate()
    transport.deliveryGate = gate
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    monitor.submit(previous: nil, current: reading(18, at: t0), now: t0)
    await gate.waitUntilBlocked()
    monitor.updateSettings(QuotaAlertSettings(enabled: false))
    gate.release()
    await monitor.waitUntilIdle()
    XCTAssertEqual(store.state, QuotaEventState())
  }

  @MainActor
  func testRefreshWaitsForForegroundPermissionAndDenialDoesNotConsume() async {
    let transport = Transport()
    transport.permission = .notDetermined
    let gate = Gate()
    transport.requestGate = gate
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    monitor.requestAuthorization()
    await gate.waitUntilBlocked()
    monitor.submit(previous: nil, current: reading(18, at: t0), now: t0)
    gate.release()
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.count, 1)

    transport.permission = .denied
    monitor.submit(previous: nil, current: reading(3, at: t0 + 900), now: t0 + 900)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.count, 1)
    transport.permission = .authorized
    monitor.submit(previous: nil, current: reading(3, at: t0 + 1_800), now: t0 + 1_800)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.map(\.threshold), [20, 5])
    XCTAssertEqual(transport.authorizationRequests, 1, "refreshes must not ask for permission")
  }

  @MainActor
  func testAddFailureIsReportedAndRetriedWithoutConsumingEvent() async {
    let transport = Transport()
    transport.failAccount = "a"
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    monitor.submit(previous: nil, current: reading(18, at: t0), now: t0)
    await monitor.waitUntilIdle()
    XCTAssertEqual(store.state, QuotaEventState())
    XCTAssertEqual(store.issues, [.deliveryFailed])

    transport.failAccount = nil
    monitor.submit(previous: nil, current: reading(18, at: t0 + 900), now: t0 + 900)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.attempts.map(\.accountID), ["a", "a"])
    XCTAssertEqual(transport.delivered.count, 1)
  }

  @MainActor
  func testPartialDeliveryRetriesOnlyTheUnacceptedEvent() async {
    let transport = Transport()
    transport.failAccount = "b"
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    let first = reading(18, accounts: ["a", "b"], at: t0)
    monitor.submit(previous: nil, current: first, now: t0)
    await monitor.waitUntilIdle()
    transport.failAccount = nil
    monitor.submit(previous: first, current: reading(18, accounts: ["a", "b"], at: t0 + 900), now: t0 + 900)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.attempts.map(\.accountID), ["a", "b", "b"])
    XCTAssertEqual(transport.delivered.map(\.accountID), ["a", "b"])
  }

  @MainActor
  func testWindowEndRearmsEvenWhenQuotaStaysLow() async {
    let transport = Transport()
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true, warningPercent: 25, criticalPercent: 10))
    let first = reading(20, at: t0)
    monitor.submit(previous: nil, current: first, now: t0)
    await monitor.waitUntilIdle()
    monitor.submit(previous: first, current: reading(20, at: t0 + 7_200), now: t0 + 7_200)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.map(\.threshold), [25, 25])
  }

  @MainActor
  func testFailureCopyNeverIncludesResponseTextAndRecoveryAlerts() async throws {
    let transport = Transport()
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    let failure = ProviderFailure(accountID: "a", provider: .anthropic, kind: .auth,
                                  message: "response-body-secret: token rejected")
    let failing = QuotaSnapshot(generatedAt: t0, providers: [], failures: [failure])
    monitor.submit(previous: nil, current: failing, now: t0)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.map(\.kind), [.failure])
    XCTAssertFalse(transport.delivered.contains { ($0.title + $0.body(now: t0)).contains("response-body-secret") })
    let stateJSON = String(decoding: try JSONEncoder().encode(store.state), as: UTF8.self)
    XCTAssertFalse(stateJSON.contains("response-body-secret"))

    monitor.submit(previous: failing, current: reading(80, at: t0 + 900), now: t0 + 900)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.map(\.kind), [.failure, .recovered])
  }

  @MainActor
  func testDeniedResetAndRejectedRecoveryRemainRetryable() async {
    let transport = Transport()
    let store = Store()
    let monitor = store.monitor(transport)
    monitor.updateSettings(QuotaAlertSettings(enabled: true))
    let low = reading(3, at: t0)
    monitor.submit(previous: nil, current: low, now: t0)
    await monitor.waitUntilIdle()
    transport.permission = .denied
    let reset = reading(100, at: t0 + 7_200)
    monitor.submit(previous: low, current: reset, now: t0 + 7_200)
    await monitor.waitUntilIdle()
    transport.permission = .authorized
    monitor.submit(previous: reset, current: reading(99, at: t0 + 8_100), now: t0 + 8_100)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.map(\.kind), [.threshold, .reset])

    let failing = QuotaSnapshot(generatedAt: t0 + 9_000, providers: [], failures: [ProviderFailure(
      accountID: "a", provider: .anthropic, kind: .decoding, message: "response body")])
    monitor.submit(previous: reset, current: failing, now: t0 + 9_000)
    await monitor.waitUntilIdle()
    transport.failAccount = "a"
    let recovered = reading(99, at: t0 + 9_900)
    monitor.submit(previous: failing, current: recovered, now: t0 + 9_900)
    await monitor.waitUntilIdle()
    XCTAssertEqual(store.state.failureLatches.count, 1)
    transport.failAccount = nil
    monitor.submit(previous: recovered, current: reading(98, at: t0 + 10_800), now: t0 + 10_800)
    await monitor.waitUntilIdle()
    XCTAssertEqual(transport.delivered.map(\.kind), [.threshold, .reset, .failure, .recovered])
    XCTAssertTrue(store.state.failureLatches.isEmpty)
  }

  @MainActor
  private final class Store {
    var state = QuotaEventState()
    var issues: [QuotaNotificationIssue] = []

    func monitor(_ transport: Transport) -> QuotaNotificationMonitor {
      QuotaNotificationMonitor(transport: transport, loadState: { self.state },
                               saveState: { self.state = $0 }, reportIssue: { self.issues.append($0) })
    }
  }

  @MainActor
  private final class Transport: QuotaNotificationTransport {
    var permission = QuotaNotificationAuthorization.authorized
    var authorizationGate: Gate?
    var requestGate: Gate?
    var deliveryGate: Gate?
    var failAccount: String?
    var authorizationRequests = 0
    var attempts: [QuotaEvent] = []
    var delivered: [QuotaEvent] = []

    func authorization() async -> QuotaNotificationAuthorization {
      let gate = authorizationGate
      authorizationGate = nil
      await gate?.block()
      return permission
    }

    func requestAuthorization() async throws -> QuotaNotificationAuthorization {
      authorizationRequests += 1
      await requestGate?.block()
      permission = .authorized
      return permission
    }

    func deliver(_ event: QuotaEvent, now: Date) async throws {
      attempts.append(event)
      let gate = deliveryGate
      deliveryGate = nil
      await gate?.block()
      if event.accountID == failAccount { throw DeliveryError.rejected }
      delivered.append(event)
    }
  }

  private enum DeliveryError: Error { case rejected }

  /// Continuations force an interleaving without sleeps or scheduler guesses.
  @MainActor
  private final class Gate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func block() async {
      await withCheckedContinuation {
        blocked = $0
        observer?.resume()
        observer = nil
      }
    }

    func waitUntilBlocked() async {
      if blocked != nil { return }
      await withCheckedContinuation { observer = $0 }
    }

    func release() {
      blocked?.resume()
      blocked = nil
    }
  }
}
