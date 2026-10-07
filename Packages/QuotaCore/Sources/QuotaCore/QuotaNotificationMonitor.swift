import Foundation

public enum QuotaNotificationAuthorization: Equatable, Sendable {
  case notDetermined, authorized, denied
}

/// Platform delivery reports acceptance by returning, and failure by throwing.
@MainActor
public protocol QuotaNotificationTransport: AnyObject {
  func authorization() async -> QuotaNotificationAuthorization
  func requestAuthorization() async throws -> QuotaNotificationAuthorization
  func deliver(_ event: QuotaEvent, now: Date) async throws
}

public enum QuotaNotificationIssue: Equatable, Sendable {
  case stateLoadFailed, stateSaveFailed, authorizationFailed, deliveryFailed
}

/// Owns notification authorization, detection and caller-injected persistence.
@MainActor
public final class QuotaNotificationMonitor {
  private let transport: any QuotaNotificationTransport
  private let saveState: (QuotaEventState) throws -> Void
  private let reportIssue: (QuotaNotificationIssue) -> Void
  private var settings = QuotaAlertSettings()
  private var state: QuotaEventState
  private var operations: [Operation] = []
  private var drainTask: Task<Void, Never>?
  private var previous: QuotaSnapshot?
  private var hasPrevious = false

  private enum Operation {
    case settings(QuotaAlertSettings)
    case authorize
    case evaluate(previous: QuotaSnapshot?, current: QuotaSnapshot, names: [String: String], now: Date)
  }

  public init(
    transport: any QuotaNotificationTransport,
    loadState: () throws -> QuotaEventState?,
    saveState: @escaping (QuotaEventState) throws -> Void,
    reportIssue: @escaping (QuotaNotificationIssue) -> Void = { _ in }
  ) {
    self.transport = transport
    self.saveState = saveState
    self.reportIssue = reportIssue
    do {
      state = try loadState() ?? QuotaEventState()
    } catch {
      state = QuotaEventState()
      reportIssue(.stateLoadFailed)
    }
  }

  public func updateSettings(_ settings: QuotaAlertSettings) {
    enqueue(.settings(settings))
  }

  /// Called from a foreground settings action, never from a refresh.
  public func requestAuthorization() {
    enqueue(.authorize)
  }

  public func submit(
    previous: QuotaSnapshot?, current: QuotaSnapshot,
    accountNames: [String: String] = [:], now: Date = Date()
  ) {
    enqueue(.evaluate(previous: previous, current: current, names: accountNames, now: now))
  }

  public func waitUntilIdle() async {
    await drainTask?.value
  }

  private func enqueue(_ operation: Operation) {
    operations.append(operation)
    guard drainTask == nil else { return }
    // MainActor alone is reentrant across awaits. One drain owns state until
    // delivery and persistence finish; later jobs cannot capture stale state.
    drainTask = Task {
      while !operations.isEmpty {
        await process(operations.removeFirst())
      }
      drainTask = nil
    }
  }

  private func process(_ operation: Operation) async {
    switch operation {
    case .settings(let settings):
      self.settings = settings
      if !settings.enabled {
        previous = nil
        hasPrevious = false
        persist(QuotaEventState())
      }
    case .authorize:
      guard settings.enabled, await transport.authorization() == .notDetermined else { return }
      do {
        _ = try await transport.requestAuthorization()
      } catch {
        reportIssue(.authorizationFailed)
      }
    case .evaluate(let prior, let current, let names, let now):
      guard settings.enabled else { return }
      if !hasPrevious {
        previous = prior
        hasPrevious = true
      }
      // Denial leaves the state and comparison snapshot unconsumed. A later
      // authorized refresh can still observe a reset or recovery.
      guard await transport.authorization() == .authorized else { return }
      let detection = QuotaEvents.detect(previous: previous, current: current, now: now,
                                         config: settings.eventConfig, state: state, accountNames: names)
      var accepted: Set<QuotaEvent> = []
      for event in detection.events {
        do {
          try await transport.deliver(event, now: now)
          accepted.insert(event)
        } catch {
          reportIssue(.deliveryFailed)
        }
      }
      persist(detection.acknowledging(accepted))
      if accepted.count == detection.events.count { previous = current }
    }
  }

  private func persist(_ state: QuotaEventState) {
    self.state = state
    do {
      try saveState(state)
    } catch {
      reportIssue(.stateSaveFailed)
    }
  }
}
