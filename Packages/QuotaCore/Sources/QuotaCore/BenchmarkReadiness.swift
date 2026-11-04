import Foundation

/// The same reasons that disable Run are visible beside it. Editor IDs belong
/// to one plan; stale validation from a removed or replaced setup is ignored.
public struct BenchmarkReadiness: Equatable, Sendable {
  public let reasons: [String]
  public var isReady: Bool { reasons.isEmpty }

  public init(plan: BenchmarkPlan, accountUseConfirmed: Bool, invalidEditorIDs: Set<UUID>) {
    var reasons: [String] = []
    do { _ = try plan.validated() }
    catch { reasons.append(error.localizedDescription) }
    for candidate in plan.candidates where invalidEditorIDs.contains(candidate.id) {
      reasons.append("Agent “\(candidate.name)”: finish model selection or correct the highlighted command or cost fields.")
    }
    for judge in plan.judges where invalidEditorIDs.contains(judge.id) {
      reasons.append("Judge “\(judge.name)”: finish model selection or correct the highlighted command fields.")
    }
    if !accountUseConfirmed {
      reasons.append("Confirm that the CLI logins match the selected accounts and those accounts are idle elsewhere.")
    }
    self.reasons = reasons
  }
}
