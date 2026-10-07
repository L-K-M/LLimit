import Foundation
#if canImport(os)
import os
#endif

private let maximumStoreQuarantines = 5

/// Display consumers preserve files; the owning refresh process may recover them.
public enum StoreReadPolicy: Sendable {
  case preserve
  case recover
}

func reportPersistenceIssue(_ message: String) {
  #if canImport(os)
  Logger(subsystem: "app.llimit.LLimit", category: "persistence").error("\(message, privacy: .public)")
  #else
  FileHandle.standardError.write(Data("LLimit: \(message)\n".utf8))
  #endif
}

/// Preserve each undecodable document before rebuilding its derived store.
/// Read failures never enter this path, and a failed move must stop recovery.
func quarantineCorruptFile(at fileURL: URL) -> Bool {
  let prefix = fileURL.lastPathComponent + ".corrupt-"
  let quarantined = fileURL.deletingLastPathComponent()
    .appendingPathComponent(prefix + UUID().uuidString)
  do {
    try FileManager.default.moveItem(at: fileURL, to: quarantined)
    // Order retention by quarantine time, not an old source file's age.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: quarantined.path)
  } catch {
    reportPersistenceIssue("Could not quarantine \(fileURL.lastPathComponent); recovery stopped.")
    return false
  }

  let directory = fileURL.deletingLastPathComponent()
  do {
    let candidates = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
    let ranked = try candidates.filter { url in
      let name = url.lastPathComponent
      guard name.hasPrefix(prefix) else { return false }
      return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
      .compactMap { url -> (url: URL, date: Date)? in
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { return nil }
        return (url, values.contentModificationDate ?? .distantPast)
      }
      .sorted { lhs, rhs in
        lhs.date == rhs.date ? lhs.url.lastPathComponent > rhs.url.lastPathComponent : lhs.date > rhs.date
      }
    // Enumeration can return different URL representations on Darwin. These
    // siblings share a directory, so filenames identify the current artifact.
    let currentName = quarantined.lastPathComponent
    let retained = Set(ranked.filter { $0.url.lastPathComponent != currentName }
      .prefix(maximumStoreQuarantines - 1).map { $0.url.lastPathComponent }).union([currentName])
    for entry in ranked where !retained.contains(entry.url.lastPathComponent) {
      try FileManager.default.removeItem(at: entry.url)
    }
  } catch {
    reportPersistenceIssue("Could not prune old quarantines for \(fileURL.lastPathComponent).")
  }
  return true
}
