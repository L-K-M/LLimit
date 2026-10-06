import Foundation
import QuotaCore

/// Read-only status access, independent of credential-bearing settings and reconciliation.
public enum StatusReader {
  public static func loadSnapshot(paths: LinuxPaths) throws -> QuotaSnapshot? {
    try SnapshotStore(fileURL: paths.snapshotFileURL).load()
  }
}
