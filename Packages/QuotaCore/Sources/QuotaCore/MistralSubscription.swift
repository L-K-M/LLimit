import Foundation
import CoreFoundation

/// The Admin page embeds its subscription props in React Flight JSON records.
/// Decode the transport as data; never execute scripts or search arbitrary text
/// for a percentage (the same page also contains spending caps and plan prices).
struct MistralSubscription {
  struct Budget {
    let usedPercent: Double?
    let allowance: Double
    let currency: String
    let resetAt: Date?
  }
  let userID: String
  let organizationID: String
  let organizationName: String?
  let api: Budget
  let vibe: Budget

  init(html: String) throws {
    let records = try Self.flightRecords(html: html)
    var candidates: [[String: Any]] = []
    func visit(_ value: Any, depth: Int) throws {
      guard depth <= 64 else { throw Self.invalid }
      if let object = value as? [String: Any] {
        if object["budget"] != nil, object["user"] != nil, object["subscriptions"] != nil,
           object["billingInfo"] != nil { candidates.append(object) }
        for child in object.values { try visit(child, depth: depth + 1) }
      } else if let array = value as? [Any] {
        for child in array { try visit(child, depth: depth + 1) }
      }
    }
    for record in records.values { try visit(record, depth: 0) }
    guard candidates.count == 1, let props = candidates.first,
          let budget = props["budget"] as? [String: Any],
          let api = budget["api_budget"] as? [String: Any],
          let vibe = budget["vibe_budget"] as? [String: Any],
          let user = try Self.resolve(props["user"], records: records) as? [String: Any],
          let userID = Self.identifier(user["uuid"]),
          let organization = user["organization"] as? [String: Any],
          let organizationID = Self.identifier(organization["uuid"]) else { throw Self.invalid }
    self.userID = userID
    self.organizationID = organizationID
    organizationName = (organization["name"] as? String).flatMap {
      $0.isEmpty || $0.count > 128 || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        ? nil : $0
    }
    self.api = try Self.budget(api)
    self.vibe = try Self.budget(vibe)
  }

  private static func budget(_ object: [String: Any]) throws -> Budget {
    guard let allowance = number(object["initial_budget"]), allowance >= 0,
          let currency = object["currency"] as? String, currency.utf8.count == 3,
          currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw invalid }
    var used: Double?
    if let value = object["usage_percentage"], !(value is NSNull) {
      guard let percent = number(value), percent >= 0 else { throw invalid }
      used = allowance > 0 ? percent : nil
    }
    var reset: Date?
    if let value = object["reset_at"], !(value is NSNull) {
      guard let text = value as? String, text.contains("T"), let date = parseISO8601(text) else { throw invalid }
      reset = date
    }
    return Budget(usedPercent: used, allowance: allowance, currency: currency, resetAt: reset)
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return nil }
    return number.doubleValue
  }

  private static func identifier(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128,
          value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
    return value
  }

  private static func resolve(_ value: Any?, records: [String: Any], depth: Int = 0) throws -> Any? {
    guard depth < 16 else { throw invalid }
    guard let reference = value as? String, reference.hasPrefix("$") else { return value }
    let path = reference.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let recordID = path.first, let record = records[recordID] else { throw invalid }
    var current: Any? = record
    for component in path.dropFirst() {
      current = try resolve(current, records: records, depth: depth + 1)
      if component == "props", let element = current as? [Any], element.count == 4,
         element[0] as? String == "$" {
        current = element[3]
      } else if let object = current as? [String: Any] {
        current = object[component]
      } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
        current = array[index]
      } else { throw invalid }
    }
    return try resolve(current, records: records, depth: depth + 1)
  }

  private static func flightRecords(html: String) throws -> [String: Any] {
    guard html.utf8.count <= 5_000_000 else { throw invalid }
    let scriptPattern = try NSRegularExpression(pattern: "<script\\b[^>]*>([\\s\\S]*?)</script\\s*>",
                                                options: [.caseInsensitive])
    let prefix = "self.__next_f.push("
    var stream = ""
    for match in scriptPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range(at: 1), in: html) else { continue }
      let script = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
      guard script.hasPrefix(prefix) else { continue }
      let bytes = Array(script.dropFirst(prefix.count).utf8)
      guard let end = containerEnd(bytes, start: 0),
            let frame = try? JSONSerialization.jsonObject(with: Data(bytes[0..<end])) as? [Any],
            frame.count == 2, number(frame[0]) == 1, let payload = frame[1] as? String else { continue }
      let suffix = String(decoding: bytes[end...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      guard suffix == ")" || suffix == ");" else { throw invalid }
      stream += payload
    }
    let bytes = Array(stream.utf8)
    var cursor = 0
    var records: [String: Any] = [:]
    while cursor < bytes.count {
      if bytes[cursor] == 10 { cursor += 1; continue }
      let start = cursor
      while cursor < bytes.count, bytes[cursor] != 58, bytes[cursor] != 10 { cursor += 1 }
      guard cursor < bytes.count, bytes[cursor] == 58 else { throw invalid }
      let id = String(decoding: bytes[start..<cursor], as: UTF8.self)
      guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
      cursor += 1
      if cursor < bytes.count, bytes[cursor] == 84 {
        // Flight's length-prefixed text records may contain newlines and JSON.
        // Skip their byte length so text cannot impersonate subscription props.
        cursor += 1
        let lengthStart = cursor
        while cursor < bytes.count, bytes[cursor] != 44 { cursor += 1 }
        guard cursor < bytes.count,
              let length = Int(String(decoding: bytes[lengthStart..<cursor], as: UTF8.self), radix: 16),
              length >= 0, length <= bytes.count - cursor - 1 else { throw invalid }
        cursor += 1 + length
        continue
      }
      let valueStart = cursor
      while cursor < bytes.count, bytes[cursor] != 10 { cursor += 1 }
      let data = Data(bytes[valueStart..<cursor])
      if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        guard records[id] == nil, records.count < 10_000 else { throw invalid }
        records[id] = value
      }
    }
    return records
  }

  private static func containerEnd(_ bytes: [UInt8], start: Int) -> Int? {
    guard start < bytes.count, bytes[start] == 91 else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    for index in start..<bytes.count {
      let byte = bytes[index]
      if inString {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { inString = false }
      } else if byte == 34 { inString = true }
      else if byte == 91 || byte == 123 { depth += 1 }
      else if byte == 93 || byte == 125 {
        depth -= 1
        if depth == 0 { return index + 1 }
      }
    }
    return nil
  }

  static var invalid: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "Mistral returned incomplete or invalid subscription data. Try again later.")
  }
}
