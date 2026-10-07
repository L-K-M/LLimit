import Foundation
import QuotaCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The opt-in alert settings of `llimit daemon`: `--notify` (or
/// `LLIMIT_NOTIFY=1`, for the systemd unit), `--on-event <cmd>` and
/// `--thresholds <list>`. With none of the delivery options set, the daemon
/// behaves exactly as before: no detection and no state file.
public struct DaemonAlertOptions: Equatable, Sendable {
  public static let notifyEnvironmentKey = "LLIMIT_NOTIFY"

  public var desktopNotifications = false
  /// An executable path, or a name looked up on PATH. Run without a shell, so
  /// it takes no arguments of its own.
  public var hookCommand: String?
  public var thresholds = QuotaEventConfig.defaultThresholds

  public var isDeliveryEnabled: Bool { desktopNotifications || hookCommand != nil }

  public init() {}

  public static func parse(arguments: [String], environment: [String: String]) throws -> DaemonAlertOptions {
    var options = DaemonAlertOptions()
    options.desktopNotifications = try isNotifySettingEnabled(environment[notifyEnvironmentKey])

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      func takeValue() throws -> String {
        guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
          throw DaemonAlertError.missingValue(argument)
        }
        index += 1
        return arguments[index]
      }

      switch argument {
      case "--notify":
        options.desktopNotifications = true
      case "--on-event":
        options.hookCommand = try takeValue()
      case "--thresholds":
        options.thresholds = try parseThresholds(takeValue())
      default:
        throw DaemonAlertError.unknownOption(argument)
      }
      index += 1
    }

    return options
  }

  private static func isNotifySettingEnabled(_ value: String?) throws -> Bool {
    let normalized = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    switch normalized {
    case "", "0", "false", "no", "off":
      return false
    case "1", "true", "yes", "on":
      return true
    default:
      throw DaemonAlertError.invalidNotifySetting(value ?? "")
    }
  }

  private static func parseThresholds(_ value: String) throws -> [Int] {
    let parts = value.split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let thresholds = parts.compactMap(Int.init)
    guard
      !parts.isEmpty,
      thresholds.count == parts.count,
      thresholds.allSatisfy(QuotaEventConfig.validThresholds.contains)
    else {
      throw DaemonAlertError.invalidThresholds(value)
    }
    return Array(Set(thresholds)).sorted(by: >)
  }
}

public enum DaemonAlertError: LocalizedError, Equatable, Sendable {
  case unknownOption(String)
  case missingValue(String)
  case invalidThresholds(String)
  case invalidNotifySetting(String)
  case hookNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .unknownOption(let option):
      return "unknown daemon option: \(option)"
    case .missingValue(let option):
      return "\(option) needs a value"
    case .invalidThresholds(let value):
      return "--thresholds expects comma-separated percentages from 1 to 99, for example 20,5 (got \"\(value)\")"
    case .invalidNotifySetting(let value):
      return "\(DaemonAlertOptions.notifyEnvironmentKey) must be 1 or 0 (got \"\(value)\")"
    case .hookNotFound(let command):
      return "--on-event: \(command) is not an executable file or a command on PATH"
    }
  }
}

/// Turns every saved snapshot into quota alerts: runs the shared QuotaCore
/// detector, persists what it announced (so a restart does not repeat it),
/// then hands each event to the configured deliveries.
public final class QuotaAlertMonitor {
  private let stateStore: QuotaEventStateStore
  private let config: QuotaEventConfig
  private let sinks: [QuotaEventSink]
  private let log: (String) -> Void
  /// Loaded on the first refresh, then kept in memory: the daemon is the only
  /// writer of the state file.
  private var state: QuotaEventState?

  init(stateFileURL: URL, config: QuotaEventConfig, sinks: [QuotaEventSink], log: @escaping (String) -> Void) {
    self.stateStore = QuotaEventStateStore(fileURL: stateFileURL)
    self.config = config
    self.sinks = sinks
    self.log = log
  }

  /// Builds the monitor `llimit daemon` runs, or nil when no delivery is
  /// enabled. A missing notify-send is reported once here and leaves the other
  /// deliveries working; a hook that cannot be found is an error, so a typo
  /// cannot silently disable it.
  public static func make(
    options: DaemonAlertOptions,
    paths: LinuxPaths,
    environment: [String: String],
    log: @escaping (String) -> Void
  ) throws -> QuotaAlertMonitor? {
    guard options.isDeliveryEnabled else {
      if options.thresholds != QuotaEventConfig.defaultThresholds {
        log("[llimitd] Warning: --thresholds has no effect without --notify, --on-event or \(DaemonAlertOptions.notifyEnvironmentKey)=1.")
      }
      return nil
    }

    var sinks: [QuotaEventSink] = []
    var descriptions: [String] = []

    if let command = options.hookCommand {
      guard let hook = ExecutableLocator.find(command, environment: environment) else {
        throw DaemonAlertError.hookNotFound(command)
      }
      sinks.append(EventHookSink(executable: hook, runner: ChildProcessRunner(log: log), inheritedEnvironment: environment))
      descriptions.append("hook \(hook.path)")
    }

    if options.desktopNotifications {
      if let notifySend = ExecutableLocator.find(DesktopNotificationSink.command, environment: environment) {
        sinks.append(DesktopNotificationSink(executable: notifySend, runner: ChildProcessRunner(log: log), environment: environment))
        descriptions.append("desktop notifications via \(notifySend.path)")
      } else {
        log("[llimitd] Warning: desktop notifications are off because notify-send is not on PATH. Install libnotify-bin (Debian, Ubuntu) or libnotify, then restart the daemon.")
      }
    }

    guard !sinks.isEmpty else { return nil }

    let config = QuotaEventConfig(thresholds: options.thresholds)
    let thresholds = config.thresholds.map { "\($0)%" }.joined(separator: ", ")
    log("[llimitd] alerts: \(descriptions.joined(separator: ", ")); thresholds \(thresholds)")
    log("[llimitd] alerts state: \(paths.alertsStateFileURL.path)")
    return QuotaAlertMonitor(stateFileURL: paths.alertsStateFileURL, config: config, sinks: sinks, log: log)
  }

  /// Detects the events between two snapshots and delivers them. The state is
  /// saved before delivery: a crash in between loses an alert rather than
  /// repeating one after the restart. `accountNames` maps account IDs to the
  /// names an alert should use.
  public func process(
    previous: QuotaSnapshot?,
    current: QuotaSnapshot,
    accountNames: [String: String] = [:],
    now: Date = Date()
  ) {
    let known = state ?? loadState()
    let detection = QuotaEvents.detect(
      previous: previous,
      current: current,
      now: now,
      config: config,
      state: known,
      accountNames: accountNames
    )
    state = detection.state

    if detection.state != known {
      do {
        try stateStore.save(detection.state)
      } catch {
        log("[llimitd] Alert state save failed: \(error.localizedDescription)")
      }
    }

    for event in detection.events {
      log("[llimitd] Alert: \(event.title)")
      for sink in sinks {
        sink.deliver(event, now: now)
      }
    }
  }

  private func loadState() -> QuotaEventState {
    do {
      return try stateStore.load() ?? QuotaEventState()
    } catch {
      log("[llimitd] Alert state unreadable, starting fresh (current conditions alert once): \(error.localizedDescription)")
      return QuotaEventState()
    }
  }
}

/// The alerts state file: account and metric IDs, thresholds, reset times and
/// failure kinds, never credentials. Written mode 0600 all the same.
struct QuotaEventStateStore {
  let fileURL: URL

  func load() throws -> QuotaEventState? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(QuotaEventState.self, from: Data(contentsOf: fileURL))
  }

  struct WriteError: LocalizedError {
    var operation: String
    var code: Int32
    var errorDescription: String? { "\(operation) failed: \(String(cString: strerror(code)))" }
  }

  /// Writes a temporary file that is mode 0600 from the moment it exists, then
  /// renames it over the old one, so the state is never readable by others nor
  /// half-written. A mode that cannot be set fails the save.
  func save(_ state: QuotaEventState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)

    let temporaryPath = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)").path
    let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw WriteError(operation: "Creating \(temporaryPath)", code: errno)
    }
    var renamed = false
    defer {
      if !renamed {
        unlink(temporaryPath)
      }
    }

    do {
      defer { close(descriptor) }
      // The umask can only have narrowed 0600; set it exactly.
      guard fchmod(descriptor, 0o600) == 0 else {
        throw WriteError(operation: "Setting mode 0600 on \(temporaryPath)", code: errno)
      }
      try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
    }

    guard rename(temporaryPath, fileURL.path) == 0 else {
      throw WriteError(operation: "Replacing \(fileURL.path)", code: errno)
    }
    renamed = true
  }
}
