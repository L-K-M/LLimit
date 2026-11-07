import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkEvidenceQualityTests: XCTestCase {
  func testDetectsCorruptedRangesAndObjectMetadata() {
    for patch in ["@@ -20,[redacted] +20,2 @@\n source", "index abc[redacted]..def 100644"] {
      XCTAssertTrue(BenchmarkEvidenceQuality.hasRedactedPatchMetadata(in: BenchmarkRun(candidateID: UUID(), repetition: 1, patch: patch)))
    }
    let extra = BenchmarkEvidence(workspaceName: "", additionalArtifacts: [
      BenchmarkEvidenceArtifact(kind: .localBranch, name: "Artifact 1", patch: "@@ -0,0 +1,[redacted]75 @@")
    ])
    XCTAssertTrue(BenchmarkEvidenceQuality.hasRedactedPatchMetadata(in: BenchmarkRun(candidateID: UUID(), repetition: 1, evidence: extra)))
  }

  func testSourcePlaceholderAloneDoesNotFlagMetadata() {
    let patch = "@@ -20,2 +20,2 @@ secret [redacted]\n-token = old\n+token = '[redacted]'"
    XCTAssertFalse(BenchmarkEvidenceQuality.hasRedactedPatchMetadata(in: BenchmarkRun(candidateID: UUID(), repetition: 1, patch: patch)))
  }

  func testOlderVerdictsDecodeWithoutPreparationWarnings() throws {
    let data = Data("{\"judgeID\":\"\(UUID().uuidString)\",\"accepted\":false,\"score\":4,\"explanation\":\"Old verdict\"}".utf8)
    let verdict = try JSONDecoder().decode(BenchmarkEvaluation.self, from: data)
    XCTAssertNil(verdict.evidenceWarnings)
    XCTAssertTrue(verdict.isValid)
  }

  func testPreparationWarningsAreRedactedAndRetained() throws {
    let key = "warning-private-credential"
    let settings = ProviderRuntimeConfiguration(provider: .junie, isEnabled: true,
      credentials: [CredentialField.junieAPIKey: key])
    let verdict = BenchmarkEvaluation(judgeID: UUID(), accepted: false, score: 4, explanation: "Limited evidence",
      evidenceWarnings: ["Could not prepare \(key)"])
    let run = BenchmarkRun(candidateID: UUID(), repetition: 1, evaluations: [verdict])
    let plan = BenchmarkPlan(taskPrompt: "Task", rubric: "Rubric", repositoryPath: "/tmp", candidates: [], judges: [])
    let source = BenchmarkReport(baselineCommit: "fixture", plan: plan, runs: [run])
    let safe = try BenchmarkRedactor(configurations: [settings]).redact(source)
    XCTAssertEqual(safe.runs[0].evaluations[0].evidenceWarnings, ["Could not prepare [redacted]"])
  }
}
