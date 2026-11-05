import Foundation

/// Only final agent messages and reported token counts enter the benchmark report.
/// Tool traces can contain authentication material and are deliberately discarded.
public struct BenchmarkOutput: Sendable {
  public let text: String
  public let tokenUsage: BenchmarkTokenUsage?
  public let succeeded: Bool

  public static func decode(_ output: String, format: BenchmarkOutputFormat) -> BenchmarkOutput {
    decode(Data(output.utf8), format: format)
  }

  static func decode(_ data: Data, format: BenchmarkOutputFormat,
                     shouldCancel: (() -> Bool)? = nil) -> BenchmarkOutput {
    if shouldCancel?() == true { return BenchmarkOutput(text: "", tokenUsage: nil, succeeded: false) }
    switch format {
    case .text:
      return BenchmarkOutput(text: String(decoding: data, as: UTF8.self), tokenUsage: nil, succeeded: true)
    case .claudeJSON:
      guard let object = try? BenchmarkJSONProjection(data, shouldCancel: shouldCancel).claude(),
            object["type"] as? String == "result",
            let text = object["result"] as? String else {
        return BenchmarkOutput(text: "The agent did not return a valid Claude Code result.", tokenUsage: nil, succeeded: false)
      }
      let usage = object["usage"] as? [String: Any]
      return BenchmarkOutput(text: text, tokenUsage: usage.map(tokens),
                             succeeded: object["is_error"] as? Bool == false)
    case .codexJSON:
      var finalResponse: String?
      var usage: BenchmarkTokenUsage?
      var completed = false
      var failed = false
      do {
        try BenchmarkJSONProjection(data, shouldCancel: shouldCancel).events(format: .codexJSON) { event in
          switch event["type"] as? String {
          case "item.completed":
            if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
               let text = item["text"] as? String { finalResponse = text }
          case "turn.completed":
            completed = true
            if let counts = event["usage"] as? [String: Any] { usage = tokens(counts) }
          case "turn.failed", "error": failed = true
          default: break
          }
        }
      } catch { failed = true }
      return BenchmarkOutput(text: finalResponse ?? "", tokenUsage: usage,
                             succeeded: completed && !failed && finalResponse?.isEmpty == false)
    case .piJSON:
      return decodePi(data, shouldCancel: shouldCancel)
    case .opencodeJSON:
      return decodeOpenCode(data, shouldCancel: shouldCancel)
    }
  }

  private static func decodePi(_ data: Data, shouldCancel: (() -> Bool)?) -> BenchmarkOutput {
    var completedMessages: [[String: Any]]?
    var failed = false
    do {
      try BenchmarkJSONProjection(data, shouldCancel: shouldCancel).events(format: .piJSON) { event in
        guard let type = event["type"] as? String else { failed = true; return }
        switch type {
        case "agent_start": completedMessages = nil
        case "agent_end": completedMessages = event["willRetry"] as? Bool == true ? nil : event["messages"] as? [[String: Any]]
        case "error", "extension_error": failed = true
        default: break
        }
      }
    } catch { failed = true }
    let assistants = (completedMessages ?? []).filter { $0["role"] as? String == "assistant" }
    guard let final = assistants.last else { return BenchmarkOutput(text: "", tokenUsage: nil, succeeded: false) }
    let text = (final["content"] as? [[String: Any]] ?? []).compactMap { block -> String? in
      block["type"] as? String == "text" ? block["text"] as? String : nil
    }.joined(separator: "\n")
    let succeeded = !failed && final["stopReason"] as? String == "stop" && !text.isEmpty
    var usage = NativeTokenUsage()
    // agent_end is authoritative; message_end repeats these same messages.
    for message in assistants {
      if let counts = message["usage"] as? [String: Any] {
        usage.add(input: counts["input"], cached: counts["cacheRead"], output: counts["output"])
      }
    }
    return BenchmarkOutput(text: text, tokenUsage: succeeded ? usage.reported : nil, succeeded: succeeded)
  }

  private static func decodeOpenCode(_ data: Data, shouldCancel: (() -> Bool)?) -> BenchmarkOutput {
    var messageOrder: [String] = []
    var knownMessages: Set<String> = []
    var textOrder: [String: [String]] = [:]
    var texts: [String: [String: String]] = [:]
    var finishReasons: [String: String] = [:]
    var seenFinishes: Set<String> = []
    var seenSteps: Set<String> = []
    var usage = NativeTokenUsage()
    var failed = false
    do {
      try BenchmarkJSONProjection(data, shouldCancel: shouldCancel).events(format: .opencodeJSON) { event in
        guard let type = event["type"] as? String else { failed = true; return }
        if type == "error" { failed = true; return }
        guard ["text", "step_start", "step_finish", "tool_use", "reasoning"].contains(type) else { return }
        guard let part = event["part"] as? [String: Any],
              let messageID = part["messageID"] as? String, !messageID.isEmpty else { failed = true; return }
        if type == "text", part["ignored"] as? Bool == true || part["synthetic"] as? Bool == true { return }
        // State-changing parts need a durable identity. Projecting tool payloads
        // away cannot safely distinguish two anonymous steps or tool calls.
        if ["step_start", "tool_use"].contains(type), (part["id"] as? String)?.isEmpty != false {
          failed = true
          return
        }
        if knownMessages.insert(messageID).inserted {
          messageOrder.append(messageID)
          // Old message text is never final again, even if its events repeat.
          textOrder = [:]
          texts = [:]
        }
        let partID = part["id"] as? String
        let identity = partID.flatMap { $0.isEmpty ? nil : $0 }
          ?? (try? JSONSerialization.data(withJSONObject: part, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
          ?? "missing"
        let key = messageID + "\u{1f}" + identity
        switch type {
        case "text":
          guard let text = part["text"] as? String else { failed = true; return }
          guard messageID == messageOrder.last else { return }
          if texts[messageID]?[identity] == nil { textOrder[messageID, default: []].append(identity) }
          texts[messageID, default: [:]][identity] = text
        case "step_start", "tool_use":
          if seenSteps.insert(type + "\u{1f}" + key).inserted {
            finishReasons[messageID] = nil
            if type == "step_start" {
              textOrder[messageID] = nil
              texts[messageID] = nil
            }
          }
        case "step_finish":
          guard seenFinishes.insert(key).inserted else { return }
          guard let reason = part["reason"] as? String else { failed = true; return }
          finishReasons[messageID] = reason
          if let counts = part["tokens"] as? [String: Any] {
            let cache = counts["cache"] as? [String: Any]
            // OpenCode's output already reports the output count. Reasoning and
            // cache writes are separate fields, not extra output tokens.
            usage.add(input: counts["input"], cached: cache?["read"], output: counts["output"])
          }
        default: break
        }
      }
    } catch { failed = true }
    guard let final = messageOrder.last else { return BenchmarkOutput(text: "", tokenUsage: nil, succeeded: false) }
    let text = (textOrder[final] ?? []).compactMap { texts[final]?[$0] }.joined(separator: "\n")
    let succeeded = !failed && finishReasons[final] == "stop" && !text.isEmpty
    return BenchmarkOutput(text: text, tokenUsage: succeeded ? usage.reported : nil, succeeded: succeeded)
  }

  /// A fresh run can omit its final stream event. Only recover the exact,
  /// unambiguous session named by its own structured events, never "latest".
  public static func openCodeSessionForRecovery(_ output: String) -> String? {
    openCodeSessionForRecovery(Data(output.utf8))
  }

  static func openCodeSessionForRecovery(_ data: Data, shouldCancel: (() -> Bool)? = nil) -> String? {
    var sessions: Set<String> = []
    var seen = false
    var failed = false
    do {
      try BenchmarkJSONProjection(data, shouldCancel: shouldCancel).events(format: .opencodeJSON) { event in
        seen = true
        guard let type = event["type"] as? String, type != "error" else { failed = true; return }
        if let error = event["error"], !(error is NSNull) { failed = true; return }
        for value in [event["sessionID"], (event["part"] as? [String: Any])?["sessionID"]].compactMap({ $0 }) {
          guard let id = value as? String, validOpenCodeSessionID(id) else { failed = true; return }
          sessions.insert(id)
        }
      }
    } catch { failed = true }
    return !failed && seen && sessions.count == 1 ? sessions.first : nil
  }

  /// Reads only terminal assistant text and usage from an in-memory export.
  /// Session titles, paths, prompts, tool results and provider errors are ignored.
  public static func decodeOpenCodeExport(_ output: String, expectedSessionID: String? = nil) -> BenchmarkOutput {
    decodeOpenCodeExport(Data(output.utf8), expectedSessionID: expectedSessionID)
  }

  static func decodeOpenCodeExport(_ data: Data, expectedSessionID: String? = nil,
                                   shouldCancel: (() -> Bool)? = nil) -> BenchmarkOutput {
    let failure = BenchmarkOutput(text: "", tokenUsage: nil, succeeded: false)
    guard let object = try? BenchmarkJSONProjection(data, shouldCancel: shouldCancel).openCodeExport(),
          let session = object["info"] as? [String: Any], let sessionID = session["id"] as? String,
          validOpenCodeSessionID(sessionID), expectedSessionID == nil || expectedSessionID == sessionID,
          let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else { return failure }
    var order: [String] = []
    var byID: [String: [String: Any]] = [:]
    for message in messages {
      guard let info = message["info"] as? [String: Any],
            info["sessionID"] as? String == sessionID,
            let id = info["id"] as? String, !id.isEmpty,
            let role = info["role"] as? String, ["user", "assistant"].contains(role),
            let parts = message["parts"] as? [[String: Any]] else { return failure }
      for part in parts {
        if let value = part["sessionID"], value as? String != sessionID { return failure }
        if let value = part["messageID"], value as? String != id { return failure }
      }
      if byID[id] == nil { order.append(id) }
      byID[id] = message
    }
    guard let finalID = order.last, let final = byID[finalID],
          let info = final["info"] as? [String: Any], info["role"] as? String == "assistant",
          info["finish"] as? String == "stop", info["summary"] as? Bool != true else { return failure }
    if let error = info["error"], !(error is NSNull) { return failure }
    if let value = info["time"] {
      guard let time = value as? [String: Any] else { return failure }
      if let completed = time["completed"] {
        guard let number = completed as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue.isFinite, number.doubleValue > 0 else { return failure }
      }
    }
    var textOrder: [String] = []
    var texts: [String: String] = [:]
    var seenSteps: Set<String> = []
    for part in final["parts"] as? [[String: Any]] ?? [] {
      let identity = (part["id"] as? String)
        ?? (try? JSONSerialization.data(withJSONObject: part, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        ?? "missing"
      if part["type"] as? String == "step-start", seenSteps.insert(identity).inserted {
        textOrder = []
        texts = [:]
      }
      if part["type"] as? String == "tool", let state = part["state"] as? [String: Any],
         ["pending", "running"].contains(state["status"] as? String ?? "") { return failure }
      guard part["type"] as? String == "text", part["ignored"] as? Bool != true,
            part["synthetic"] as? Bool != true, let text = part["text"] as? String else { continue }
      if texts[identity] == nil { textOrder.append(identity) }
      texts[identity] = text
    }
    let text = textOrder.compactMap { texts[$0] }.joined(separator: "\n")
    guard !text.isEmpty else { return failure }
    var usage = NativeTokenUsage()
    for id in order {
      guard let info = byID[id]?["info"] as? [String: Any], info["role"] as? String == "assistant",
            let counts = info["tokens"] as? [String: Any] else { continue }
      let cache = counts["cache"] as? [String: Any]
      usage.add(input: counts["input"], cached: cache?["read"], output: counts["output"])
    }
    return BenchmarkOutput(text: text, tokenUsage: usage.reported, succeeded: true)
  }

  private static func validOpenCodeSessionID(_ id: String) -> Bool {
    id.hasPrefix("ses_") && (5...128).contains(id.utf8.count) && id.utf8.dropFirst(4).allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
  }

  private struct NativeTokenUsage {
    private static let limit = 1_000_000_000_000
    private var input = 0
    private var cached = 0
    private var output = 0
    private var hasReportedUsage = false

    mutating func add(input: Any?, cached: Any?, output: Any?) {
      hasReportedUsage = true
      self.input = min(Self.limit, self.input + Self.count(input))
      self.cached = min(Self.limit, self.cached + Self.count(cached))
      self.output = min(Self.limit, self.output + Self.count(output))
    }

    var reported: BenchmarkTokenUsage? {
      hasReportedUsage ? BenchmarkTokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output) : nil
    }

    private static func count(_ value: Any?) -> Int {
      guard let number = value as? NSNumber else { return 0 }
      let count = number.doubleValue
      guard count.isFinite, count >= 0 else { return 0 }
      return Int(min(Double(limit), count).rounded(.towardZero))
    }
  }

  private static func tokens(_ object: [String: Any]) -> BenchmarkTokenUsage {
    func count(_ key: String) -> Int { min(1_000_000_000_000, max(0, (object[key] as? NSNumber)?.intValue ?? 0)) }
    return BenchmarkTokenUsage(inputTokens: count("input_tokens"), cachedInputTokens: count("cached_input_tokens") + count("cache_read_input_tokens"),
                               outputTokens: count("output_tokens"))
  }

  public static func evaluation(_ text: String, judgeID: UUID,
                                redactor: BenchmarkRedactor = BenchmarkRedactor(configurations: [])) -> BenchmarkEvaluation {
    struct Verdict: Decodable { let accepted: Bool; let score: Double; let explanation: String }
    // A single fenced JSON object is common even when the prompt requests JSON only.
    var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix("```"), let newline = json.firstIndex(of: "\n"), json.hasSuffix("```") {
      json = String(json[json.index(after: newline)..<json.index(json.endIndex, offsetBy: -3)])
    }
    guard let data = json.data(using: .utf8), let verdict = try? JSONDecoder().decode(Verdict.self, from: data),
          verdict.score.isFinite, (0...10).contains(verdict.score),
          !verdict.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return BenchmarkEvaluation(judgeID: judgeID, explanation: "", error: "The judge did not return a valid verdict.")
    }
    return BenchmarkEvaluation(judgeID: judgeID, accepted: verdict.accepted, score: verdict.score,
                               explanation: String(redactor.redact(verdict.explanation).prefix(12_000)))
  }
}

/// Redacts owned credentials, including individual values inside cookie/JSON containers.
/// Reports are local private files, never part of the widget snapshot or history.
public struct BenchmarkRedactor: Sendable {
  private let secrets: [String]

  public init(configurations: [ProviderRuntimeConfiguration]) {
    let hiddenKeys: Set<String> = [CredentialField.openAIRefreshToken, CredentialField.kimiRefreshToken,
      CredentialField.mimoBrowserSession, CredentialField.stepFunBrowserSession,
      CredentialField.mistralBrowserSession, CredentialField.longcatBrowserSession]
    var values: Set<String> = []
    for configuration in configurations {
      let keys = Set(configuration.provider.credentialFields.filter(\.isSecret).map(\.key)).union(hiddenKeys)
      for (key, value) in configuration.credentials where keys.contains(key) && !value.isEmpty {
        values.insert(value)
        // JSON browser-session containers also contain public names, domains and
        // paths. Redact their authentication values, never every string leaf.
        let isJSON = value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        for cookie in isJSON ? [] : value.split(separator: ";") {
          if let equals = cookie.firstIndex(of: "=") {
            let secret = String(cookie[cookie.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !secret.isEmpty { values.insert(secret); values.insert(secret.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
          }
        }
        if configuration.provider == .stepFun { value.components(separatedBy: "...").forEach { if !$0.isEmpty { values.insert($0) } } }
      }
      if let raw = configuration.credentials[CredentialField.mimoBrowserSession], let session = try? MiMoBrowserSession(serialized: raw) { values.formUnion(session.secretValues) }
      if let raw = configuration.credentials[CredentialField.stepFunBrowserSession], let session = try? StepFunBrowserSession(serialized: raw) { values.formUnion(session.secretValues) }
      if let raw = configuration.credentials[CredentialField.mistralBrowserSession], let session = try? MistralBrowserSession(serialized: raw) { values.formUnion(session.secretValues) }
      if let raw = configuration.credentials[CredentialField.mistralSessionCookies], let session = try? MistralSessionCookies(header: raw) { values.formUnion(session.secretValues) }
      if let raw = configuration.credentials[CredentialField.longcatBrowserSession], let session = try? LongcatBrowserSession(serialized: raw) { values.formUnion(session.secretValues) }
      if let raw = configuration.credentials[CredentialField.longcatSessionCookies], let session = try? LongcatSessionCookies(header: raw) { values.formUnion(session.secretValues) }
    }
    secrets = values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
  }

  public func redact(_ text: String) -> String {
    secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
  }

  private init(secrets: [String]) { self.secrets = secrets }

  public func merging(_ other: BenchmarkRedactor) -> BenchmarkRedactor {
    BenchmarkRedactor(secrets: Set(secrets + other.secrets).sorted { $0.count > $1.count })
  }

  public func redact(_ report: BenchmarkReport) throws -> BenchmarkReport {
    func command(_ original: BenchmarkCommand) -> BenchmarkCommand {
      var copy = original
      copy.arguments = original.arguments.map(redact)
      return copy
    }
    // Never rewrite typed IDs or enum raw values: a short cookie value such as
    // "1" can otherwise corrupt UUIDs and make an otherwise valid report unreadable.
    var copy = report
    copy.plan.taskPrompt = redact(report.plan.taskPrompt)
    copy.plan.rubric = redact(report.plan.rubric)
    copy.plan.acceptanceCommand = report.plan.acceptanceCommand.map(redact)
    copy.plan.candidates = report.plan.candidates.map {
      var candidate = $0
      candidate.name = redact($0.name)
      candidate.command = command($0.command)
      return candidate
    }
    copy.plan.judges = report.plan.judges.map {
      var judge = $0
      judge.name = redact($0.name)
      judge.command = command($0.command)
      return judge
    }
    copy.runs = report.runs.map {
      var run = $0
      run.output = redact($0.output)
      run.patch = redact($0.patch)
      run.costBasis = $0.costBasis.map(redact)
      run.quotaChanges = $0.quotaChanges.map {
        var change = $0
        change.label = redact($0.label)
        change.unavailableReason = $0.unavailableReason.map(redact)
        return change
      }
      run.evaluations = $0.evaluations.map {
        var evaluation = $0
        evaluation.explanation = redact($0.explanation)
        evaluation.error = $0.error.map(redact)
        return evaluation
      }
      return run
    }
    copy.warnings = report.warnings.map(redact)
    return copy
  }
}
