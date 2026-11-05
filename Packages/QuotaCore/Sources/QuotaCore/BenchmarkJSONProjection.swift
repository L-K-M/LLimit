import Foundation

/// Projects only benchmark evidence from a seekable transcript. In particular,
/// Pi's terminal event repeats its entire tool history in one JSON value.
struct BenchmarkJSONProjection {
  private let data: Data
  private let document: BenchmarkJSONDocument

  init(_ data: Data, shouldCancel: (() -> Bool)? = nil) {
    self.data = data
    document = BenchmarkJSONDocument(data, shouldCancel: shouldCancel)
  }

  private enum Invalid: Error { case structure }

  func events(format: BenchmarkOutputFormat, _ consume: ([String: Any]) -> Void) throws {
    var start = data.startIndex
    for index in data.indices {
      if (index - data.startIndex) & 0xFFFF == 0 { try document.checkCancellation() }
      if data[index] == 0x0A {
        try record(start..<index, format: format, consume)
        start = index + 1
      }
    }
    try record(start..<data.endIndex, format: format, consume)
  }

  private func record(_ range: Range<Int>, format: BenchmarkOutputFormat,
                      _ consume: ([String: Any]) -> Void) throws {
    if format == .codexJSON {
      // Codex can mix diagnostics with its JSON stream. Preserve its existing
      // per-record leniency; only structured terminal events establish success.
      try? event(range, format: format, consume)
    } else {
      try event(range, format: format, consume)
    }
  }

  private func event(_ range: Range<Int>, format: BenchmarkOutputFormat,
                     _ consume: ([String: Any]) -> Void) throws {
    try document.checkCancellation()
    var hasValue = false
    for index in range {
      if (index - range.lowerBound) & 0xFFFF == 0 { try document.checkCancellation() }
      if ![0x20, 0x09, 0x0D, 0x0A].contains(data[index]) { hasValue = true; break }
    }
    guard hasValue else { return }
    let fields = try document.fields(range, keeping: ["type", "messages", "willRetry", "item", "usage", "part", "sessionID", "error"])
    var event: [String: Any] = [:]
    putString("type", fields, into: &event)
    putString("sessionID", fields, into: &event)
    if let error = fields["error"] { event["error"] = isNull(error) ? NSNull() : true }
    let type = event["type"] as? String
    switch format {
    case .piJSON:
      if type == "agent_end" {
        if let retry = fields["willRetry"] { event["willRetry"] = try scalar(retry) }
        if let messages = fields["messages"] { event["messages"] = try piMessages(messages) }
      }
    case .codexJSON:
      if type == "item.completed", let range = fields["item"] {
        let itemFields = try document.fields(range, keeping: ["type", "text"])
        var item: [String: Any] = [:]
        putString("type", itemFields, into: &item)
        if item["type"] as? String == "agent_message" { putString("text", itemFields, into: &item) }
        event["item"] = item
      }
      if type == "turn.completed", let range = fields["usage"], isObject(range) {
        event["usage"] = try counts(range, keys: ["input_tokens", "cached_input_tokens", "cache_read_input_tokens", "output_tokens"])
      }
    case .opencodeJSON:
      if let range = fields["part"] { event["part"] = try openCodePart(range, type: type, export: false) }
    default: break
    }
    consume(event)
  }

  func claude() throws -> [String: Any] {
    try document.checkCancellation()
    let fields = try document.fields(document.whole, keeping: ["type", "result", "is_error", "usage"])
    var result: [String: Any] = [:]
    for key in ["type", "result"] { putString(key, fields, into: &result) }
    if let value = fields["is_error"] { result["is_error"] = try scalar(value) }
    if let value = fields["usage"], isObject(value) {
      result["usage"] = try counts(value, keys: ["input_tokens", "cached_input_tokens", "cache_read_input_tokens", "output_tokens"])
    }
    return result
  }

  private func piMessages(_ range: Range<Int>) throws -> [[String: Any]] {
    var finalFields: [String: Range<Int>]?
    var totals = ["input": 0, "cacheRead": 0, "output": 0]
    var reported = false
    try document.elements(range) { message in
      let fields = try document.fields(message, keeping: ["role", "content", "stopReason", "usage"])
      guard try document.string(fields["role"]) == "assistant" else { return }
      finalFields = fields
      if let range = fields["usage"], isObject(range) {
        let usage = try counts(range, keys: ["input", "cacheRead", "output"])
        reported = true
        for key in ["input", "cacheRead", "output"] {
          guard let number = usage[key] as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else { continue }
          totals[key] = min(1_000_000_000_000, totals[key, default: 0] + Int(min(1_000_000_000_000, number.doubleValue)))
        }
      }
    }
    guard let fields = finalFields else { return [] }
    var final: [String: Any] = ["role": "assistant"]
    putString("stopReason", fields, into: &final)
    var blocks: [[String: Any]] = []
    if let content = fields["content"] {
      try document.elements(content) { block in
        let fields = try document.fields(block, keeping: ["type", "text"])
        guard try document.string(fields["type"]) == "text", let text = try document.string(fields["text"]) else { return }
        blocks.append(["type": "text", "text": text])
      }
    }
    final["content"] = blocks
    if reported { final["usage"] = totals }
    return [final]
  }

  func openCodeExport() throws -> [String: Any] {
    try document.checkCancellation()
    let fields = try document.fields(document.whole, keeping: ["info", "messages"])
    guard let infoRange = fields["info"], let messagesRange = fields["messages"] else { throw Invalid.structure }
    let sessionFields = try document.fields(infoRange, keeping: ["id"])
    guard let session = try document.string(sessionFields["id"]) else { throw Invalid.structure }
    var order: [String] = []
    var messages: [String: (info: [String: Any], parts: Range<Int>)] = [:]
    try document.elements(messagesRange) { range in
      let message = try document.fields(range, keeping: ["info", "parts"])
      guard let infoRange = message["info"], let partsRange = message["parts"] else { throw Invalid.structure }
      let fields = try document.fields(infoRange, keeping: ["id", "sessionID", "role", "finish", "summary", "error", "time", "tokens"])
      var info: [String: Any] = [:]
      for key in ["id", "sessionID", "role", "finish"] { putString(key, fields, into: &info) }
      guard let id = info["id"] as? String, !id.isEmpty, info["sessionID"] as? String == session,
            ["user", "assistant"].contains(info["role"] as? String ?? "") else { throw Invalid.structure }
      if let value = fields["summary"] { info["summary"] = try scalar(value) }
      if let value = fields["error"] { info["error"] = isNull(value) ? NSNull() : true }
      if let value = fields["time"] {
        let time = try document.fields(value, keeping: ["completed"])
        var projected: [String: Any] = [:]
        if let completed = time["completed"] { projected["completed"] = try scalar(completed) }
        info["time"] = projected
      }
      if let value = fields["tokens"], isObject(value) { info["tokens"] = try openCodeCounts(value) }
      try document.elements(partsRange) { range in
        let identity = try document.fields(range, keeping: ["sessionID", "messageID"])
        if let value = identity["sessionID"], try document.string(value) != session { throw Invalid.structure }
        if let value = identity["messageID"], try document.string(value) != id { throw Invalid.structure }
      }
      if messages[id] == nil { order.append(id) }
      messages[id] = (info, partsRange)
    }
    var projected: [[String: Any]] = []
    for id in order {
      guard let message = messages[id] else { continue }
      var parts: [[String: Any]] = []
      if id == order.last {
        try document.elements(message.parts) { range in
          parts.append(try openCodePart(range, type: nil, export: true))
        }
      }
      projected.append(["info": message.info, "parts": parts])
    }
    return ["info": ["id": session], "messages": projected]
  }

  private func openCodePart(_ range: Range<Int>, type: String?, export: Bool) throws -> [String: Any] {
    let fields = try document.fields(range, keeping: ["id", "type", "sessionID", "messageID", "reason", "text", "tokens", "ignored", "synthetic", "state"])
    var part: [String: Any] = [:]
    for key in ["id", "type", "sessionID", "messageID", "reason"] { putString(key, fields, into: &part) }
    let kind = export ? part["type"] as? String : type
    if export, kind == "step-start", (part["id"] as? String)?.isEmpty != false { throw Invalid.structure }
    for key in ["ignored", "synthetic"] {
      if let range = fields[key] { part[key] = try scalar(range) }
    }
    if kind == "text", part["ignored"] as? Bool != true, part["synthetic"] as? Bool != true {
      putString("text", fields, into: &part)
    }
    if kind == "step_finish", let range = fields["tokens"], isObject(range) { part["tokens"] = try openCodeCounts(range) }
    if export, kind == "tool", let range = fields["state"] {
      let state = try document.fields(range, keeping: ["status"])
      var projected: [String: Any] = [:]
      putString("status", state, into: &projected)
      part["state"] = projected
    }
    // Anonymous finish records can be deduplicated by their evidence fields.
    // Anonymous state-changing records are rejected by their consumer.
    return part
  }

  private func openCodeCounts(_ range: Range<Int>) throws -> [String: Any] {
    var result = try counts(range, keys: ["input", "output"])
    let fields = try document.fields(range, keeping: ["cache"])
    if let cache = fields["cache"], isObject(cache) { result["cache"] = try counts(cache, keys: ["read"]) }
    return result
  }

  private func counts(_ range: Range<Int>, keys: Set<String>) throws -> [String: Any] {
    let fields = try document.fields(range, keeping: keys)
    var result: [String: Any] = [:]
    for (key, range) in fields { result[key] = try scalar(range) }
    return result
  }

  private func scalar(_ range: Range<Int>) throws -> Any {
    guard let first = range.first(where: { ![0x20, 0x09, 0x0D, 0x0A].contains(data[$0]) }) else { return NSNull() }
    // Wrong-type values must not cause an ignored object/string to be loaded.
    guard data[first] != 0x22, data[first] != 0x7B, data[first] != 0x5B else { return NSNull() }
    return try document.value(range)
  }

  private func isObject(_ range: Range<Int>) -> Bool {
    range.first(where: { ![0x20, 0x09, 0x0D, 0x0A].contains(data[$0]) }).map { data[$0] == 0x7B } ?? false
  }

  private func isNull(_ range: Range<Int>) -> Bool {
    range.first(where: { ![0x20, 0x09, 0x0D, 0x0A].contains(data[$0]) }).map { data[$0] == 0x6E } ?? false
  }

  private func putString(_ key: String, _ fields: [String: Range<Int>], into object: inout [String: Any]) {
    guard let range = fields[key] else { return }
    // Preserve a wrong-type marker: session recovery must reject a present but
    // non-string identifier rather than silently treating it as absent.
    object[key] = (try? document.string(range)) ?? true
  }
}
