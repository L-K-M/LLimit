import Foundation
import QuotaCore

/// The single read-only snapshot loader for every display and scripting command.
public enum StatusReader {
  public static func loadSnapshot(paths: LinuxPaths) throws -> QuotaSnapshot? {
    try SnapshotStore(fileURL: paths.snapshotFileURL).load(policy: .preserve)
  }
}
