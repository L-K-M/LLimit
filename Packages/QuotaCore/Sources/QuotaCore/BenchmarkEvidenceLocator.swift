import Foundation

/// Legacy runs used unrelated random workspace names. Recover a mapping only
/// when a single directory was created during that recorded attempt.
public enum BenchmarkEvidenceLocator {
  public static func workspace(for run: BenchmarkRun, in report: BenchmarkReport, directory: URL) throws -> URL? {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
      .appendingPathComponent((report.artifactReportID ?? report.id).uuidString, isDirectory: true)
    guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { return nil }
    func valid(_ name: String) -> URL? {
      guard name.hasPrefix("trial-"), UUID(uuidString: String(name.dropFirst(6))) != nil else { return nil }
      let url = root.appendingPathComponent(name, isDirectory: true)
      guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
      return url
    }
    if let name = run.evidence?.workspaceName, !name.isEmpty { return valid(name) }
    if let exact = valid("trial-\(run.id.uuidString)") { return exact }
    guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    let next = report.runs.map(\.startedAt).filter { $0 > run.startedAt }.min()
      ?? report.finishedAt ?? Date.distantFuture
    let matches = try FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]).compactMap { url -> URL? in
        guard let candidate = valid(url.lastPathComponent),
              let created = try candidate.resourceValues(forKeys: [.creationDateKey]).creationDate,
              created >= run.startedAt, created < next else { return nil }
        return candidate
      }
    return matches.count == 1 ? matches.first : nil
  }
}
