import Foundation

/// Lightweight, non-persistent view of benchmark execution progress derived from a live report.
public struct BenchmarkProgress: Equatable, Sendable {

  /// High-level phase of the benchmark lifecycle.
  public enum Phase: String, Sendable {
    case preparing
    case runningTrial
    case waitingForQuota
    case checkingAcceptance
    case evaluating
    case completed
    case cancelled
  }

  /// Current lifecycle phase.
  public let phase: Phase

  /// Number of trial runs recorded so far (completed, failed, timed out, or cancelled).
  public let completedAttempts: Int

  /// Total number of trial runs expected (candidates × repetitions, defensively clamped).
  public let totalAttempts: Int

  /// Evaluations recorded across all runs.
  public let completedEvaluations: Int

  /// Evaluations expected: completed runs × judges count; stabilizes once evaluation begins.
  public let totalEvaluations: Int

  /// Candidate currently being run, if any.
  public let currentCandidateID: UUID?

  /// Repetition index currently being run, if any.
  public let currentRepetition: Int?

  /// Judge currently evaluating, if any.
  public let currentJudgeID: UUID?

  /// Timestamp when the benchmark started.
  public let startedAt: Date

  /// Fraction of trial runs completed, bounded to 0...1.
  public var attemptFraction: Double {
    guard totalAttempts > 0 else { return 0 }
    return min(1, max(0, Double(completedAttempts) / Double(totalAttempts)))
  }

  /// Fraction of evaluations completed, bounded to 0...1; denominator stabilizes once evaluation begins.
  public var evaluationFraction: Double {
    guard totalEvaluations > 0 else { return 0 }
    return min(1, max(0, Double(completedEvaluations) / Double(totalEvaluations)))
  }

  /// True only when the benchmark has reached a terminal phase.
  public var isTerminal: Bool {
    phase == .completed || phase == .cancelled
  }

  /// Derive progress from a benchmark report and the current execution phase.
  ///
  /// - Parameters:
  ///   - report: The current benchmark report (may be empty or partial).
  ///   - phase: The execution phase observed by the runner.
  ///   - currentCandidateID: The candidate ID currently being executed, if any.
  ///   - currentRepetition: The repetition index currently being executed, if any.
  ///   - currentJudgeID: The judge ID currently evaluating, if any.
  public init(
    report: BenchmarkReport,
    phase: Phase,
    currentCandidateID: UUID? = nil,
    currentRepetition: Int? = nil,
    currentJudgeID: UUID? = nil
  ) {
    self.phase = phase
    self.currentCandidateID = currentCandidateID
    self.currentRepetition = currentRepetition
    self.currentJudgeID = currentJudgeID
    self.startedAt = report.startedAt

    // completedAttempts: every run in the report counts as one attempt.
    self.completedAttempts = report.runs.count

    // totalAttempts: candidates × repetitions, defensively clamped to known valid max (10 × 20).
    let candidates = min(report.plan.candidates.count, 10)
    let repetitions = min(max(report.plan.repetitions, 0), 20)
    self.totalAttempts = candidates * repetitions

    // completedEvaluations: sum of evaluations across all runs.
    self.completedEvaluations = report.runs.reduce(0) { $0 + $1.evaluations.count }

    // totalEvaluations: only completed runs are judged; judges count from plan.
    let judgesCount = report.plan.judges.count
    let completedRuns = report.runs.filter { $0.outcome == .completed }.count
    self.totalEvaluations = completedRuns * judgesCount
  }
}
