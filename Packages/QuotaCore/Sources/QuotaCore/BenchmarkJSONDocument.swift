import Foundation

/// A range-based JSON reader for harness receipts. Unknown values are validated
/// without allocating strings, arrays or dictionaries for tool output/history.
struct BenchmarkJSONDocument {
  let data: Data
  private let shouldCancel: (() -> Bool)?
  var whole: Range<Int> { data.startIndex..<data.endIndex }

  init(_ data: Data, shouldCancel: (() -> Bool)? = nil) {
    self.data = data
    self.shouldCancel = shouldCancel
  }

  func checkCancellation() throws {
    if shouldCancel?() == true { throw CancellationError() }
  }

  func fields(_ range: Range<Int>, keeping keys: Set<String>) throws -> [String: Range<Int>] {
    try checkCancellation()
    var cursor = range.lowerBound
    try whitespace(&cursor, end: range.upperBound)
    guard take(0x7B, &cursor, end: range.upperBound) else { throw InvalidJSON() }
    var result: [String: Range<Int>] = [:]
    try whitespace(&cursor, end: range.upperBound)
    if !take(0x7D, &cursor, end: range.upperBound) {
      while true {
        let start = cursor
        try skipString(&cursor, end: range.upperBound)
        let keyRange = start..<cursor
        // An escaped ASCII key uses at most six bytes per character. Avoid
        // decoding arbitrarily large keys that cannot match a requested field.
        let maxKeyBytes = (keys.map(\.utf8.count).max() ?? 0) * 6 + 2
        let key = keyRange.count <= maxKeyBytes ? try string(keyRange) : nil
        try whitespace(&cursor, end: range.upperBound)
        guard take(0x3A, &cursor, end: range.upperBound) else { throw InvalidJSON() }
        try whitespace(&cursor, end: range.upperBound)
        let valueStart = cursor
        try skipValue(&cursor, end: range.upperBound, depth: 0)
        if let key, keys.contains(key) { result[key] = valueStart..<cursor }
        try whitespace(&cursor, end: range.upperBound)
        if take(0x7D, &cursor, end: range.upperBound) { break }
        guard take(0x2C, &cursor, end: range.upperBound) else { throw InvalidJSON() }
        try whitespace(&cursor, end: range.upperBound)
      }
    }
    try whitespace(&cursor, end: range.upperBound)
    guard cursor == range.upperBound else { throw InvalidJSON() }
    return result
  }

  func elements(_ range: Range<Int>, _ body: (Range<Int>) throws -> Void) throws {
    try checkCancellation()
    var cursor = range.lowerBound
    try whitespace(&cursor, end: range.upperBound)
    guard take(0x5B, &cursor, end: range.upperBound) else { throw InvalidJSON() }
    try whitespace(&cursor, end: range.upperBound)
    if !take(0x5D, &cursor, end: range.upperBound) {
      while true {
        let start = cursor
        try skipValue(&cursor, end: range.upperBound, depth: 0)
        try body(start..<cursor)
        try whitespace(&cursor, end: range.upperBound)
        if take(0x5D, &cursor, end: range.upperBound) { break }
        guard take(0x2C, &cursor, end: range.upperBound) else { throw InvalidJSON() }
        try whitespace(&cursor, end: range.upperBound)
      }
    }
    try whitespace(&cursor, end: range.upperBound)
    guard cursor == range.upperBound else { throw InvalidJSON() }
  }

  func value(_ range: Range<Int>) throws -> Any {
    try checkCancellation()
    return try JSONSerialization.jsonObject(with: data.subdata(in: range), options: [.fragmentsAllowed])
  }

  func string(_ range: Range<Int>?) throws -> String? {
    guard let range, range.lowerBound < range.upperBound, data[range.lowerBound] == 0x22 else { return nil }
    return try value(range) as? String
  }

  private func whitespace(_ cursor: inout Int, end: Int) throws {
    while cursor < end, [0x20, 0x09, 0x0A, 0x0D].contains(data[cursor]) {
      if cursor & 0xFFFF == 0 { try checkCancellation() }
      cursor += 1
    }
  }

  private func take(_ byte: UInt8, _ cursor: inout Int, end: Int) -> Bool {
    guard cursor < end, data[cursor] == byte else { return false }
    cursor += 1
    return true
  }

  private func skipValue(_ cursor: inout Int, end: Int, depth: Int) throws {
    try checkCancellation()
    // Match Foundation's structural nesting protection. This bounds stack use,
    // independently of transcript, string, array or final-answer length.
    guard depth < 512, cursor < end else { throw InvalidJSON() }
    switch data[cursor] {
    case 0x22: try skipString(&cursor, end: end)
    case 0x7B, 0x5B:
      let object = data[cursor] == 0x7B
      let closing: UInt8 = object ? 0x7D : 0x5D
      cursor += 1
      try whitespace(&cursor, end: end)
      if take(closing, &cursor, end: end) { return }
      while true {
        if object {
          try skipString(&cursor, end: end)
          try whitespace(&cursor, end: end)
          guard take(0x3A, &cursor, end: end) else { throw InvalidJSON() }
          try whitespace(&cursor, end: end)
        }
        try skipValue(&cursor, end: end, depth: depth + 1)
        try whitespace(&cursor, end: end)
        if take(closing, &cursor, end: end) { return }
        guard take(0x2C, &cursor, end: end) else { throw InvalidJSON() }
        try whitespace(&cursor, end: end)
      }
    case 0x74: try literal("true", &cursor, end: end)
    case 0x66: try literal("false", &cursor, end: end)
    case 0x6E: try literal("null", &cursor, end: end)
    default: try number(&cursor, end: end)
    }
  }

  private func literal(_ text: StaticString, _ cursor: inout Int, end: Int) throws {
    for byte in text.withUTF8Buffer({ Array($0) }) {
      guard take(byte, &cursor, end: end) else { throw InvalidJSON() }
    }
  }

  private func number(_ cursor: inout Int, end: Int) throws {
    _ = take(0x2D, &cursor, end: end)
    guard cursor < end else { throw InvalidJSON() }
    if !take(0x30, &cursor, end: end) {
      guard (0x31...0x39).contains(data[cursor]) else { throw InvalidJSON() }
      while cursor < end, (0x30...0x39).contains(data[cursor]) {
        if cursor & 0xFFFF == 0 { try checkCancellation() }
        cursor += 1
      }
    }
    if take(0x2E, &cursor, end: end) { try digits(&cursor, end: end) }
    if cursor < end, data[cursor] == 0x65 || data[cursor] == 0x45 {
      cursor += 1
      if cursor < end, data[cursor] == 0x2B || data[cursor] == 0x2D { cursor += 1 }
      try digits(&cursor, end: end)
    }
  }

  private func digits(_ cursor: inout Int, end: Int) throws {
    let start = cursor
    while cursor < end, (0x30...0x39).contains(data[cursor]) {
      if cursor & 0xFFFF == 0 { try checkCancellation() }
      cursor += 1
    }
    guard cursor > start else { throw InvalidJSON() }
  }

  private func skipString(_ cursor: inout Int, end: Int) throws {
    guard take(0x22, &cursor, end: end) else { throw InvalidJSON() }
    var nextCancellationCheck = cursor
    while cursor < end {
      if cursor >= nextCancellationCheck {
        try checkCancellation()
        nextCancellationCheck = cursor + 65_536
      }
      let byte = data[cursor]
      cursor += 1
      if byte == 0x22 { return }
      if byte == 0x5C {
        guard cursor < end else { throw InvalidJSON() }
        let escape = data[cursor]
        cursor += 1
        if escape == 0x75 {
          for _ in 0..<4 {
            guard cursor < end, (0x30...0x39).contains(data[cursor]) || (0x41...0x46).contains(data[cursor]) || (0x61...0x66).contains(data[cursor]) else { throw InvalidJSON() }
            cursor += 1
          }
        } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) { throw InvalidJSON() }
      } else if byte < 0x20 { throw InvalidJSON() }
      else if byte >= 0x80 {
        // Validate UTF-8 without constructing discarded strings.
        let continuationCount: Int
        let firstRange: ClosedRange<UInt8>
        switch byte {
        case 0xC2...0xDF: continuationCount = 1; firstRange = 0x80...0xBF
        case 0xE0: continuationCount = 2; firstRange = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: continuationCount = 2; firstRange = 0x80...0xBF
        case 0xED: continuationCount = 2; firstRange = 0x80...0x9F
        case 0xF0: continuationCount = 3; firstRange = 0x90...0xBF
        case 0xF1...0xF3: continuationCount = 3; firstRange = 0x80...0xBF
        case 0xF4: continuationCount = 3; firstRange = 0x80...0x8F
        default: throw InvalidJSON()
        }
        guard end - cursor >= continuationCount, firstRange.contains(data[cursor]) else { throw InvalidJSON() }
        cursor += 1
        for _ in 1..<continuationCount {
          guard (0x80...0xBF).contains(data[cursor]) else { throw InvalidJSON() }
          cursor += 1
        }
      }
    }
    throw InvalidJSON()
  }

  struct InvalidJSON: Error {}
}
