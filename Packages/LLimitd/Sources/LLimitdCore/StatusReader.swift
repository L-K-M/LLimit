import Foundation
import QuotaCore

/// Display commands read only the credential-free snapshot and never recover files.
public enum StatusReader {
  public static func loadSnapshot(paths: LinuxPaths) throws -> QuotaSnapshot? {
    try SnapshotStore(fileURL: paths.snapshotFileURL).load(policy: .preserve)
  }
}
