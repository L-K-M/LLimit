import Foundation

public enum BenchmarkOutputFormat: String, Codable, CaseIterable, Sendable {
  case text
  case codexJSON
  case claudeJSON
  case piJSON
  case opencodeJSON
}

public struct BenchmarkCommand: Codable, Hashable, Sendable {
  public var executable: String
  public var arguments: [String]
  public var outputFormat: BenchmarkOutputFormat

  public init(executable: String, arguments: [String] = [], outputFormat: BenchmarkOutputFormat = .text) {
    self.executable = executable
    self.arguments = arguments
    self.outputFormat = outputFormat
  }
}

public struct BenchmarkCandidate: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var command: BenchmarkCommand
  public var accountID: String?
  public var quotaMetricID: String?
  /// User-allocated cost of the selected metric's complete allowance, in the plan currency.
  public var allowanceCost: Double?

  public init(id: UUID = UUID(), name: String, command: BenchmarkCommand, accountID: String? = nil,
              quotaMetricID: String? = nil, allowanceCost: Double? = nil) {
    self.id = id
    self.name = name
    self.command = command
    self.accountID = accountID
    self.quotaMetricID = quotaMetricID
    self.allowanceCost = allowanceCost
  }
}

public struct BenchmarkJudge: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var command: BenchmarkCommand

  public init(id: UUID = UUID(), name: String, command: BenchmarkCommand) {
    self.id = id
    self.name = name
    self.command = command
  }
}

public enum BenchmarkValidationError: LocalizedError, Equatable {
  case invalid(String)

  public var errorDescription: String? {
    if case .invalid(let message) = self { return message }
    return nil
  }
}

public struct BenchmarkPlan: Codable, Hashable, Sendable {
  public var taskPrompt: String
  public var rubric: String
  public var repositoryPath: String
  public var repetitions: Int
  public var timeoutSeconds: Double
  public var settleSeconds: Double
  public var acceptanceCommand: String?
  public var currency: String
  public var candidates: [BenchmarkCandidate]
  public var judges: [BenchmarkJudge]

  public init(taskPrompt: String, rubric: String, repositoryPath: String, repetitions: Int = 3,
              timeoutSeconds: Double = 600, settleSeconds: Double = 0, acceptanceCommand: String? = nil,
              currency: String = "USD", candidates: [BenchmarkCandidate], judges: [BenchmarkJudge]) {
    self.taskPrompt = taskPrompt
    self.rubric = rubric
    self.repositoryPath = repositoryPath
    self.repetitions = repetitions
    self.timeoutSeconds = timeoutSeconds
    self.settleSeconds = settleSeconds
    self.acceptanceCommand = acceptanceCommand
    self.currency = currency
    self.candidates = candidates
    self.judges = judges
  }

  @discardableResult
  public func validated() throws -> Self {
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw BenchmarkValidationError.invalid(message) }
    }
    func nonblank(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func validateCommand(_ command: BenchmarkCommand) throws {
      try require(command.executable.hasPrefix("/") && !command.executable.contains("\0"),
                  "Choose an absolute executable path for every agent and judge.")
      try require(command.arguments.count <= 100 && command.arguments.allSatisfy { !$0.contains("\0") && $0.utf8.count <= 65_536 },
                  "Command arguments must contain no NUL characters and stay within the command size limits.")
    }
    try require(nonblank(taskPrompt) && taskPrompt.utf8.count <= 131_072,
                "Enter a task of at most 128 KiB.")
    try require(nonblank(rubric) && rubric.utf8.count <= 65_536,
                "Enter evaluation criteria of at most 64 KiB.")
    try require(repositoryPath.hasPrefix("/") && !repositoryPath.contains("\0"),
                "Choose an absolute repository path.")
    try require((1...20).contains(repetitions), "Repetitions must be between 1 and 20.")
    try require(timeoutSeconds.isFinite && (1...3_600).contains(timeoutSeconds),
                "The run timeout must be between 1 and 3,600 seconds.")
    try require(settleSeconds.isFinite && (0...300).contains(settleSeconds),
                "Quota reporting delay must be between 0 and 300 seconds.")
    try require((1...10).contains(candidates.count), "Choose between 1 and 10 agent setups.")
    try require(judges.count == 2, "Choose exactly two independent judges.")
    try require(Set(candidates.map(\.id)).count == candidates.count, "Each agent setup must have a unique ID.")
    try require(Set(judges.map(\.id)).count == judges.count, "Each judge must have a unique ID.")
    try require(currency.count == 3 && currency.unicodeScalars.allSatisfy { (65...90).contains($0.value) },
                "Enter an uppercase three-letter currency code, such as USD or CHF.")
    if let acceptanceCommand {
      try require(nonblank(acceptanceCommand) && !acceptanceCommand.contains("\0") && acceptanceCommand.utf8.count <= 16_384,
                  "The acceptance command must be nonblank, contain no NUL characters and fit within 16 KiB.")
    }
    for candidate in candidates {
      try require(nonblank(candidate.name) && candidate.name.count <= 200, "Enter an agent setup name of at most 200 characters.")
      try validateCommand(candidate.command)
      if let allowanceCost = candidate.allowanceCost {
        try require(allowanceCost.isFinite && allowanceCost >= 0, "Allowance costs must be finite and nonnegative.")
        try require(candidate.accountID.map(nonblank) == true && candidate.quotaMetricID.map(nonblank) == true,
                    "Choose an account and quota metric before setting an allowance cost.")
      }
    }
    for judge in judges {
      try require(nonblank(judge.name) && judge.name.count <= 200, "Enter a judge name of at most 200 characters.")
      try validateCommand(judge.command)
    }
    return self
  }
}

public struct BenchmarkTokenUsage: Codable, Hashable, Sendable {
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int

  public init(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
  }
}

public struct BenchmarkQuotaChange: Codable, Hashable, Sendable {
  public var metricID: String
  public var label: String
  public var consumedAmount: Double?
  public var consumedPercentagePoints: Double?
  public var unavailableReason: String?

  public init(metricID: String, label: String, consumedAmount: Double? = nil,
              consumedPercentagePoints: Double? = nil, unavailableReason: String? = nil) {
    self.metricID = metricID
    self.label = label
    self.consumedAmount = consumedAmount
    self.consumedPercentagePoints = consumedPercentagePoints
    self.unavailableReason = unavailableReason
  }

  /// Deltas are attributed to the run only under the user's account-exclusivity assumption.
  /// A missing, changed, replenished or rounded-away observation is never a free task.
  public static func changes(before: ProviderUsage?, after: ProviderUsage?) -> [Self] {
    let beforeMetrics = before?.metrics ?? []
    let afterMetrics = after?.metrics ?? []
    let metrics = beforeMetrics + afterMetrics.filter { next in !beforeMetrics.contains { $0.id == next.id } }
    guard !metrics.isEmpty else {
      return [Self(metricID: "unavailable", label: "Quota", unavailableReason: "Quota readings are unavailable.")]
    }
    return metrics.map { metric in
      func unavailable(_ reason: String) -> Self {
        Self(metricID: metric.id, label: metric.label, unavailableReason: reason)
      }
      guard let before, let after,
            let previous = before.metrics.first(where: { $0.id == metric.id }),
            let current = after.metrics.first(where: { $0.id == metric.id }) else {
        return unavailable("A before or after quota reading is missing.")
      }
      guard before.accountID == after.accountID && before.provider == after.provider else {
        return unavailable("The quota readings belong to different accounts.")
      }
      guard after.fetchedAt > before.fetchedAt else {
        return unavailable("The after reading is not newer than the before reading.")
      }
      guard !previous.isUnlimited && !current.isUnlimited else {
        return unavailable("Unlimited quota has no measurable allowance consumption.")
      }
      guard previous.resetAt == current.resetAt,
            previous.resetAt.map({ $0 > after.fetchedAt }) ?? true else {
        return unavailable("The quota window reset or changed during the run.")
      }
      guard previous.windowSeconds == current.windowSeconds,
            previous.expiresAt == current.expiresAt else {
        return unavailable("The quota window or expiry changed during the run.")
      }
      guard previous.totalAmount == current.totalAmount,
            previous.estimatedTotal == current.estimatedTotal,
            previous.estimateKeyHash == current.estimateKeyHash else {
        return unavailable("The allowance denominator or authentication context changed during the run.")
      }

      var amount: Double?
      var percentage: Double?
      if let oldAmount = previous.remainingAmount, let newAmount = current.remainingAmount {
        guard oldAmount.isFinite && newAmount.isFinite && oldAmount >= 0 && newAmount >= 0 else {
          return unavailable("The provider reported an invalid remaining amount.")
        }
        guard newAmount <= oldAmount else { return unavailable("The remaining quota increased during the run.") }
        amount = oldAmount - newAmount
        if let total = previous.totalAmount ?? previous.estimatedTotal, total.isFinite && total > 0 {
          let rawPercentage = (oldAmount - newAmount) / total * 100
          if rawPercentage.isFinite { percentage = rawPercentage }
        }
      }
      if percentage == nil, let oldPercent = previous.remainingPercent, let newPercent = current.remainingPercent {
        guard (0...100).contains(oldPercent) && (0...100).contains(newPercent) else {
          return unavailable("The provider reported an invalid remaining percentage.")
        }
        guard newPercent <= oldPercent else { return unavailable("The remaining quota increased during the run.") }
        if oldPercent > newPercent { percentage = Double(oldPercent - newPercent) }
      }
      guard amount != nil || percentage != nil else {
        return unavailable("The change is below percentage resolution, or the provider did not report comparable values.")
      }
      return Self(metricID: metric.id, label: metric.label, consumedAmount: amount, consumedPercentagePoints: percentage,
                  unavailableReason: percentage == nil ? "A percentage cost cannot be calculated from this reading." : nil)
    }
  }
}

public enum BenchmarkOutcome: String, Codable, Sendable {
  case completed
  case failed
  case timedOut
  case cancelled
}

public struct BenchmarkEvaluation: Codable, Hashable, Sendable {
  public var judgeID: UUID
  public var accepted: Bool?
  public var score: Double?
  public var explanation: String
  public var error: String?

  public init(judgeID: UUID, accepted: Bool? = nil, score: Double? = nil, explanation: String = "", error: String? = nil) {
    self.judgeID = judgeID
    self.accepted = accepted
    self.score = score
    self.explanation = explanation
    self.error = error
  }

  public var isValid: Bool {
    error == nil && accepted != nil && score.map { $0.isFinite && (0...10).contains($0) } == true
  }
}

public struct BenchmarkRun: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var candidateID: UUID
  public var repetition: Int
  public var startedAt: Date
  public var durationSeconds: Double
  public var outcome: BenchmarkOutcome
  public var output: String
  public var patch: String
  public var acceptancePassed: Bool?
  public var quotaChanges: [BenchmarkQuotaChange]
  public var estimatedCost: Double?
  public var tokenUsage: BenchmarkTokenUsage?
  public var evaluations: [BenchmarkEvaluation]

  public init(id: UUID = UUID(), candidateID: UUID, repetition: Int, startedAt: Date = Date(),
              durationSeconds: Double = 0, outcome: BenchmarkOutcome = .completed, output: String = "", patch: String = "",
              acceptancePassed: Bool? = nil, quotaChanges: [BenchmarkQuotaChange] = [], estimatedCost: Double? = nil,
              tokenUsage: BenchmarkTokenUsage? = nil, evaluations: [BenchmarkEvaluation] = []) {
    self.id = id
    self.candidateID = candidateID
    self.repetition = repetition
    self.startedAt = startedAt
    self.durationSeconds = durationSeconds
    self.outcome = outcome
    self.output = output
    self.patch = patch
    self.acceptancePassed = acceptancePassed
    self.quotaChanges = quotaChanges
    self.estimatedCost = estimatedCost
    self.tokenUsage = tokenUsage
    self.evaluations = evaluations
  }

  /// Missing or conflicting judgments require review rather than silently becoming successes.
  public var isAccepted: Bool? {
    guard outcome == .completed, acceptancePassed != false else { return false }
    guard evaluations.count == 2, Set(evaluations.map(\.judgeID)).count == 2,
          evaluations.allSatisfy(\.isValid) else { return nil }
    let votes = evaluations.compactMap(\.accepted)
    return votes[0] == votes[1] ? votes[0] : nil
  }
}

public struct BenchmarkSummary: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID { candidateID }
  public let candidateID: UUID
  public let name: String
  public let attempts: Int
  public let acceptedCount: Int
  public let medianDurationSeconds: Double?
  public let minDurationSeconds: Double?
  public let maxDurationSeconds: Double?
  public let estimatedTotalCost: Double?
  public let estimatedCostPerAcceptedTask: Double?
  public let meanQualityScore: Double?

  public var successRate: Double? { attempts > 0 ? Double(acceptedCount) / Double(attempts) : nil }
}

public struct BenchmarkReport: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var startedAt: Date
  public var finishedAt: Date?
  public var baselineCommit: String
  public var plan: BenchmarkPlan
  public var runs: [BenchmarkRun]
  public var judgeDurationSeconds: Double
  public var warnings: [String]

  public init(id: UUID = UUID(), startedAt: Date = Date(), finishedAt: Date? = nil, baselineCommit: String,
              plan: BenchmarkPlan, runs: [BenchmarkRun] = [], judgeDurationSeconds: Double = 0, warnings: [String] = []) {
    self.id = id
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.baselineCommit = baselineCommit
    self.plan = plan
    self.runs = runs
    self.judgeDurationSeconds = judgeDurationSeconds
    self.warnings = warnings
  }

  public var summaries: [BenchmarkSummary] {
    plan.candidates.map { candidate in
      let attempts = runs.filter { $0.candidateID == candidate.id }
      let accepted = attempts.filter { $0.isAccepted == true }.count
      let durations = attempts.map(\.durationSeconds).filter { $0.isFinite && $0 >= 0 }.sorted()
      let median: Double?
      if durations.isEmpty {
        median = nil
      } else if durations.count.isMultiple(of: 2) {
        median = durations[durations.count / 2 - 1] / 2 + durations[durations.count / 2] / 2
      } else {
        median = durations[durations.count / 2]
      }
      let costs = attempts.compactMap(\.estimatedCost).filter { $0.isFinite && $0 >= 0 }
      let sum = costs.reduce(0, +)
      let completeCost = !attempts.isEmpty && costs.count == attempts.count && sum.isFinite ? sum : nil
      let scores = attempts.flatMap(\.evaluations).filter(\.isValid).compactMap(\.score)
      return BenchmarkSummary(candidateID: candidate.id, name: candidate.name, attempts: attempts.count, acceptedCount: accepted,
                              medianDurationSeconds: median, minDurationSeconds: durations.first, maxDurationSeconds: durations.last,
                              estimatedTotalCost: completeCost,
                              estimatedCostPerAcceptedTask: accepted > 0 ? completeCost.map { $0 / Double(accepted) } : nil,
                              meanQualityScore: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count))
    }
  }
}
