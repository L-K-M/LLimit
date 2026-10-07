import Foundation
import UserNotifications
import QuotaCore

@MainActor
enum QuotaNotifications {
  private static let stateDefaultsKey = "LLimitQuotaEventState"

  static func makeMonitor() -> QuotaNotificationMonitor {
    QuotaNotificationMonitor(
      transport: NativeQuotaNotificationTransport(),
      loadState: {
        guard let data = UserDefaults.standard.data(forKey: stateDefaultsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuotaEventState.self, from: data)
      },
      saveState: { state in
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try encoder.encode(state), forKey: stateDefaultsKey)
      },
      reportIssue: { issue in
        // Transport errors can contain external text. Log only the typed issue.
        print("[LLimit] Quota notification: \(issue)")
      }
    )
  }
}

@MainActor
private final class NativeQuotaNotificationTransport: NSObject, QuotaNotificationTransport, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private static let identifierPrefix = "LLimit.quota."

  override init() {
    super.init()
    center.delegate = self
  }

  func authorization() async -> QuotaNotificationAuthorization {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return .authorized
    case .notDetermined:
      return .notDetermined
    default:
      return .denied
    }
  }

  func requestAuthorization() async throws -> QuotaNotificationAuthorization {
    try await center.requestAuthorization(options: [.alert, .sound]) ? .authorized : .denied
  }

  func deliver(_ event: QuotaEvent, now: Date) async throws {
    let content = UNMutableNotificationContent()
    content.title = event.title
    content.body = event.body(now: now)
    content.sound = .default
    // Length-prefixed components avoid collisions when a metric ID contains ":".
    let components = [event.kind.rawValue, event.accountID, event.metricID ?? "", event.threshold.map(String.init) ?? ""]
    let identifier = Self.identifierPrefix + components.map { "\($0.utf8.count):\($0)" }.joined()
    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
