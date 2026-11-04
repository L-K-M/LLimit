import Foundation

/// Only final agent messages and reported token counts enter the benchmark report.
/// Tool traces can contain authentication material and are deliberately discarded.
public struct BenchmarkOutput: Sendable {
  public let text: String
  public let tokenUsage: BenchmarkTokenUsage?
  public let succeeded: Bool

  public static func decode(_ output: String, format: BenchmarkOutputFormat) -> BenchmarkOutput {
    switch format {
    case .text:
      return BenchmarkOutput(text: output, tokenUsage: nil, succeeded: true)
    case .claudeJSON:
      guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
      for line in output.split(separator: "\n") {
        guard let data = String(line).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
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
      return BenchmarkOutput(text: finalResponse ?? "", tokenUsage: usage,
                             succeeded: completed && !failed && finalResponse?.isEmpty == false)
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
