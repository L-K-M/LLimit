import Foundation

/// Benchmark prompts and artifacts are private local data and never enter the widget store.
public struct BenchmarkReportStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public func save(_ report: BenchmarkReport) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeOwnerOnlyAtomically(encoder.encode(report), to: fileURL(id: report.id))
  }

  public func load(id: UUID) throws -> BenchmarkReport? {
    let url = fileURL(id: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try decode(at: url, expectedID: id)
  }

  private func decode(at url: URL, expectedID: UUID) throws -> BenchmarkReport {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
    guard report.id == expectedID else { throw BenchmarkValidationError.invalid("The benchmark report ID does not match its file.") }
    return report
  }

  /// Corrupt reports remain on disk and produce an error instead of disappearing from history.
  public func list() throws -> [BenchmarkReport] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let reports = try files.compactMap { url -> BenchmarkReport? in
      guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
      return try decode(at: url, expectedID: id)
    }
    return reports.sorted { lhs, rhs in
      if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func fileURL(id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
  }
}
