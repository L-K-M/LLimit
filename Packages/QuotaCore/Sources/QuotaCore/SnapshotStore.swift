import Foundation

/// Persists the latest quota snapshot. The file is written and read with
/// owner-only (`0600`) permissions: snapshots contain no credentials, but they
/// do carry account titles and usage details that don't need to be
/// world-readable.
public final class SnapshotStore: @unchecked Sendable {
  private let fileURL: URL
  private let appGroupIdentifier: String?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL, appGroupIdentifier: String? = nil) {
    self.fileURL = fileURL
    self.appGroupIdentifier = appGroupIdentifier
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  #if canImport(Darwin)
  public convenience init(appGroupIdentifier: String, fileName: String) {
    let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )!.appendingPathComponent(fileName)
    self.init(fileURL: url, appGroupIdentifier: appGroupIdentifier)
  }
  #endif

  public func load() throws -> QuotaSnapshot? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL)
    let snapshot: QuotaSnapshot
    do {
      snapshot = try decoder.decode(QuotaSnapshot.self, from: data)
    } catch {
      FileHandle.standardError.write(Data(
        "LLimit: snapshot decode failed; quarantined \(fileURL.lastPathComponent): \(error)\n".utf8
      ))
      quarantineCorruptFile(fileURL)
      return nil
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return snapshot
  }

  public func save(_ snapshot: QuotaSnapshot) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try encoder.encode(snapshot)
    try data.write(to: fileURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func debugInfo() -> String {
    var info = "File URL: \(fileURL.path)\n"
    info += "Exists: \(FileManager.default.fileExists(atPath: fileURL.path))\n"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
      info += "Size: \(attrs[.size] ?? "unknown")\n"
      info += "Permissions: \(attrs[.posixPermissions] ?? "unknown")\n"
    }
    if let appGroup = appGroupIdentifier {
      #if canImport(Darwin)
      if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
        info += "App Group container accessible: \(containerURL.path)\n"
      } else {
        info += "App Group container NOT accessible\n"
      }
      #else
      info += "App Group identifier: \(appGroup)\n"
      #endif
    }
    return info
  }
}
