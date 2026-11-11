import Foundation

public enum BenchmarkEvidenceQuality {
  /// Older blanket redaction could alter Git ranges and object metadata.
  /// Source placeholders alone do not establish that a patch is unusable.
  public static func hasRedactedPatchMetadata(in run: BenchmarkRun) -> Bool {
    ([run.patch] + (run.evidence?.additionalArtifacts.map(\.patch) ?? [])).contains { patch in
      guard patch.contains("[redacted]") else { return false }
      return patch.split(separator: "\n").contains { line in
        if line.hasPrefix("index ") { return line.contains("[redacted]") }
        guard line.hasPrefix("@@ ") else { return false }
        return line.dropFirst(3).prefix(while: { $0 != "@" }).contains("[redacted]")
      }
    }
  }
}
