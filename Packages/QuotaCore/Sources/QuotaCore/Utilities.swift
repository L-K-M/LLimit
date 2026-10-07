import Foundation
import CoreFoundation

func clampPercent(_ value: Int) -> Int {
  max(0, min(100, value))
}

func percentRemaining(fromUsedPercent usedPercent: Double) -> Int? {
  roundedPercent(100.0 - usedPercent)
}

public func formatShortDuration(seconds: Int) -> String {
  let safeSeconds = max(0, seconds)
  let days = safeSeconds / 86_400
  let hours = (safeSeconds % 86_400) / 3_600
  let minutes = (safeSeconds % 3_600) / 60

  var parts: [String] = []
  if days > 0 { parts.append("\(days)d") }
  if hours > 0 { parts.append("\(hours)h") }
  if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
  return parts.joined(separator: " ")
}

public func formatResetCountdown(to date: Date, now: Date) -> String {
  let interval = date.timeIntervalSince(now)
  guard interval.isFinite, interval > 0 else { return "reset" }

  let seconds = roundedInt(interval.rounded(.down)) ?? Int.max
  return formatShortDuration(seconds: seconds)
}

public extension UsageMetric {
  func resetCountdown(at date: Date) -> String? {
    if let resetAt {
      return formatResetCountdown(to: resetAt, now: date)
    }

    guard let resetIn else { return nil }
    let value = resetIn.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    let lowercased = value.lowercased()
    if lowercased == "reset" { return "reset" }
    let normalized: String
    if lowercased.hasPrefix("reset in ") {
      normalized = String(value.dropFirst(9))
    } else if lowercased.hasPrefix("in ") {
      normalized = String(value.dropFirst(3))
    } else if lowercased.hasPrefix("reset ") {
      normalized = String(value.dropFirst(6))
    } else {
      normalized = value
    }

    let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

func parseNumeric(_ value: Any?) -> Double? {
  switch value {
  case let number as NSNumber:
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let parsed = number.doubleValue
    return parsed.isFinite ? parsed : nil
  case let string as String:
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalized = trimmed.replacingOccurrences(of: ",", with: "")
    if let direct = Double(normalized), direct.isFinite {
      return direct
    }

    let pattern = "^-?\\d+(?:\\.\\d+)?"
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: normalized.count)),
      let range = Range(match.range, in: normalized)
    else {
      return nil
    }
    guard let parsed = Double(normalized[range]), parsed.isFinite else { return nil }
    return parsed
  default:
    return nil
  }
}

func firstNumeric(in dictionary: [String: Any], keys: [String]) -> Double? {
  for key in keys {
    if let parsed = parseNumeric(dictionary[key]) {
      return parsed
    }
  }
  return nil
}

func firstDateValue(in dictionary: [String: Any], keys: [String]) -> Date? {
  for key in keys {
    if let date = parseDateValue(dictionary[key]) {
      return date
    }
  }
  return nil
}

func nonEmptyString(_ value: Any?) -> String? {
  guard let string = value as? String else { return nil }
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

enum RetryAfterPolicy {
  static let maximumDelay: TimeInterval = 24 * 3_600

  static func boundedDelay(_ delay: TimeInterval?) -> TimeInterval? {
    guard let delay, delay.isFinite, delay > 0 else { return nil }
    return min(delay, maximumDelay)
  }
}

enum HTTPStatusCode {
  static let ok = 200
  static let unauthorized = 401
  static let forbidden = 403
  static let notFound = 404
  static let tooManyRequests = 429
  static let serverErrors = 500..<600
}

func errorKind(forStatusCode statusCode: Int) -> QuotaErrorKind {
  switch statusCode {
  case HTTPStatusCode.unauthorized, HTTPStatusCode.forbidden: return .auth
  case HTTPStatusCode.tooManyRequests: return .rateLimit
  default: return .api
  }
}

/// RFC 9110 delta-seconds or IMF-fixdate. Malformed guidance has no cooldown.
func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
  guard let value = nonEmptyString(value) else { return nil }
  if value.allSatisfy({ ("0"..."9").contains($0) }) {
    return RetryAfterPolicy.boundedDelay(Double(value))
  }

  // Refreshes are concurrent; keep this cold-path formatter local.
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
  guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
  return RetryAfterPolicy.boundedDelay(date.timeIntervalSince(now))
}

func formatIntLike(_ value: Double?) -> String? {
  guard let value, value.isFinite else { return nil }
  if let integer = roundedInt(value), Double(integer) == value {
    return String(integer)
  }
  return String(format: "%.1f", value)
}

func formatTokensMillions(_ value: Double?) -> String? {
  guard let value, value.isFinite else { return nil }
  return String(format: "%.1fM", value / 1_000_000.0)
}

func roundedInt(_ value: Double) -> Int? {
  guard value.isFinite else { return nil }
  let rounded = value.rounded()
  guard rounded >= Double(Int.min), rounded < Double(Int.max) else { return nil }
  return Int(rounded)
}

func roundedPercent(_ value: Double) -> Int? {
  guard value.isFinite else { return nil }
  return Int(min(100, max(0, value)).rounded())
}

/// Non-cryptographic fingerprint used to detect *changes* in a credential
/// without persisting the credential itself — snapshots are credential-free.
/// This FNV-1a stamp is change provenance, not an authentication hash.
func credentialFingerprint(_ value: String) -> String {
  let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
  let prime: UInt64 = 0x0000_0100_0000_01b3
  var hash = offsetBasis
  for byte in value.utf8 {
    hash ^= UInt64(byte)
    hash &*= prime
  }
  return String(hash, radix: 16)
}

private enum CredentialEnvironmentReference {
  static let prefix = "env:"
}

public extension String {
  /// True when the value is an `env:NAME` indirection — a shell-style variable
  /// name that resolves from the process environment at runtime. Anything else
  /// (including `env:` followed by an invalid identifier) is a literal value.
  var isEnvironmentReference: Bool {
    guard hasPrefix(CredentialEnvironmentReference.prefix) else { return false }
    let name = String(dropFirst(CredentialEnvironmentReference.prefix.count))
    return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == name.startIndex..<name.endIndex
  }
}

public extension Dictionary where Key == String, Value == String {
  /// Resolves values of the form `env:NAME` from the process environment, so a
  /// credential can live outside the settings file entirely (e.g. a systemd
  /// `EnvironmentFile` for the Linux daemon). A NAME that is unset resolves to
  /// empty, which readiness checks and the provider client then report as a
  /// missing credential. Paths that write credentials back into settings must
  /// leave `isEnvironmentReference` values untouched so the pointer is never
  /// replaced by the secret it resolved to.
  func resolvingEnvironmentReferences(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    mapValues { value in
      guard value.isEnvironmentReference else { return value }
      return environment[String(value.dropFirst(CredentialEnvironmentReference.prefix.count))] ?? ""
    }
  }

  /// Automatic writes retain pointers even when their runtime copy contains secrets.
  func preservingEnvironmentReferences(from stored: [String: String]) -> [String: String] {
    merging(stored.filter { $0.value.isEnvironmentReference }) { _, reference in reference }
  }
}

func parseJSONObject(from data: Data) throws -> [String: Any] {
  let object = try JSONSerialization.jsonObject(with: data)
  guard let dictionary = object as? [String: Any] else {
    throw ProviderClientError(kind: .decoding, message: "Expected top-level JSON object")
  }
  return dictionary
}

func parseISO8601(_ string: String?) -> Date? {
  guard let string else { return nil }
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  let withFractional = ISO8601DateFormatter()
  withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

  // ISO8601DateFormatter only accepts exactly three fractional digits, but
  // protobuf-JSON timestamps (e.g. Kimi's resetTime) carry up to nine. Parse
  // the milliseconds-normalized form first so a platform that leniently
  // swallows longer fractions as raw milliseconds can't win with a wrong date.
  if let normalized = normalizedToMillisecondFraction(trimmed), let date = withFractional.date(from: normalized) {
    return date
  }

  if let date = withFractional.date(from: trimmed) {
    return date
  }

  let standard = ISO8601DateFormatter()
  standard.formatOptions = [.withInternetDateTime]
  if let date = standard.date(from: trimmed) {
    return date
  }

  let calendarDate = DateFormatter()
  calendarDate.locale = Locale(identifier: "en_US_POSIX")
  calendarDate.timeZone = TimeZone(secondsFromGMT: 0)
  calendarDate.dateFormat = "yyyy-MM-dd"
  return calendarDate.date(from: trimmed)
}

/// Rewrites an ISO 8601 string's fractional-second part to exactly three
/// digits (truncating or zero-padding), or nil when there is no fraction to
/// fix. Only the first "." is considered — ISO 8601 timestamps have one.
private func normalizedToMillisecondFraction(_ value: String) -> String? {
  guard value.contains("T"), let dotIndex = value.firstIndex(of: ".") else { return nil }

  var digits = ""
  var suffixStart = value.index(after: dotIndex)
  while suffixStart < value.endIndex, value[suffixStart].isNumber {
    digits.append(value[suffixStart])
    suffixStart = value.index(after: suffixStart)
  }
  guard !digits.isEmpty, digits.count != 3 else { return nil }

  let milliseconds = String((digits + "000").prefix(3))
  return value[..<dotIndex] + "." + milliseconds + value[suffixStart...]
}

func parseDateValue(_ value: Any?) -> Date? {
  switch value {
  case let date as Date:
    return date
  case let number as NSNumber:
    return dateFromEpochTimestamp(number.doubleValue)
  case let string as String:
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let parsedISO = parseISO8601(trimmed) {
      return parsedISO
    }

    guard let numeric = parseStrictNumericString(trimmed) else {
      return nil
    }

    return dateFromEpochTimestamp(numeric)
  default:
    return nil
  }
}

func dateFromEpochTimestamp(_ timestamp: Double) -> Date? {
  guard timestamp.isFinite else { return nil }

  let magnitude = abs(timestamp)
  let normalizedSeconds: Double

  switch magnitude {
  case 1_000_000_000_000_000_000...:
    normalizedSeconds = timestamp / 1_000_000_000
  case 1_000_000_000_000_000...:
    normalizedSeconds = timestamp / 1_000_000
  case 1_000_000_000_000...:
    normalizedSeconds = timestamp / 1_000
  default:
    normalizedSeconds = timestamp
  }

  return Date(timeIntervalSince1970: normalizedSeconds)
}

private func parseStrictNumericString(_ value: String) -> Double? {
  guard !value.isEmpty else { return nil }

  var hasDecimalPoint = false

  for (index, character) in value.enumerated() {
    if character == "-" {
      if index != 0 {
        return nil
      }
      continue
    }

    if character == "." {
      if hasDecimalPoint {
        return nil
      }
      hasDecimalPoint = true
      continue
    }

    guard character.isNumber else {
      return nil
    }
  }

  if value == "-" || value == "." || value == "-." {
    return nil
  }

  return Double(value)
}

func monthEndDate(year: Int, month: Int) -> Date? {
  var components = DateComponents()
  components.year = year
  components.month = month
  components.day = 1
  components.hour = 0
  components.minute = 0
  components.second = 0

  let calendar = Calendar(identifier: .gregorian)
  guard let startOfMonth = calendar.date(from: components) else { return nil }

  var plusOne = DateComponents()
  plusOne.month = 1
  return calendar.date(byAdding: plusOne, to: startOfMonth)
}

func startOfNextMonth(from date: Date) -> Date? {
  let calendar = Calendar(identifier: .gregorian)
  let components = calendar.dateComponents([.year, .month], from: date)

  guard let year = components.year, let month = components.month else {
    return nil
  }

  return monthEndDate(year: year, month: month)
}
