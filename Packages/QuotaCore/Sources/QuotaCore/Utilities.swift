import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func clampPercent(_ value: Int) -> Int {
  max(0, min(100, value))
}

func percentRemaining(fromUsedPercent usedPercent: Double) -> Int? {
  roundedPercent(100.0 - usedPercent)
}

func formatShortDuration(seconds: Int) -> String {
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

func formatResetCountdown(to date: Date, now: Date) -> String {
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

/// Atomically writes `data` at `fileURL` with owner-only (`0600`)
/// permissions. The payload is staged in a sibling temp file created
/// owner-only before any bytes hit disk, so the file never exists — at
/// either path — with wider permissions (a bare atomic write creates the
/// visible file at umask defaults, leaving a readable window).
func writeOwnerOnlyFile(_ data: Data, to fileURL: URL) throws {
  let directory = fileURL.deletingLastPathComponent()
  // Sweep staging siblings abandoned by a crashed writer (unique names are
  // never reused, unlike the previous fixed temp name). The hour cutoff
  // protects any concurrent writer mid-save.
  let staleCutoff = Date().addingTimeInterval(-3_600)
  if let entries = try? FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
  ) {
    for entry in entries
    where entry.lastPathComponent.hasPrefix(".\(fileURL.lastPathComponent).")
      && entry.lastPathComponent.hasSuffix(".tmp") {
      let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      if modified < staleCutoff {
        try? FileManager.default.removeItem(at: entry)
      }
    }
  }
  // Unique staging name: overlapping writers can't clobber each other's
  // temp file, and thrown-error leftovers are cleaned up by the defer.
  let tempURL = directory.appendingPathComponent(
    ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
  )
  defer { try? FileManager.default.removeItem(at: tempURL) }
  guard FileManager.default.createFile(
    atPath: tempURL.path,
    contents: nil,
    attributes: [.posixPermissions: 0o600]
  ) else {
    throw CocoaError(.fileWriteUnknown, userInfo: [
      NSLocalizedDescriptionKey:
        "staging create failed: \(String(cString: strerror(errno)))"
    ])
  }
  // Non-atomic write truncates the pre-created 0600 file in place.
  try data.write(to: tempURL)
  // rename(2) atomically replaces the destination: readers always see the
  // old or the new file, and a failed swap leaves the old file intact.
  // (replaceItemAt is unreliable on Linux corelibs and moveItem refuses to
  // clobber an existing destination.)
  guard rename(tempURL.path, fileURL.path) == 0 else {
    throw NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(errno),
      userInfo: [NSLocalizedDescriptionKey:
        "rename to \(fileURL.lastPathComponent) failed: \(String(cString: strerror(errno)))"]
    )
  }
}
