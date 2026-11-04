import Foundation

/// Private editable setup, kept separately from redacted benchmark reports.
/// Incomplete plans are valid drafts and must survive an app restart.
public struct BenchmarkDraftStore: Sendable {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> BenchmarkPlan? {
    let data: Data
    do { data = try Data(contentsOf: fileURL) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    return try JSONDecoder().decode(BenchmarkPlan.self, from: data)
  }

  public func save(_ plan: BenchmarkPlan) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(plan)
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try writeOwnerOnlyAtomically(data, to: fileURL)
  }
}
