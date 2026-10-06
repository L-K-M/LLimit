import Foundation

/// Identity of the Linux port, surfaced by `llimit --version` so scripts and
/// bug reports can name the exact build they talked to.
public enum LLimitdInfo {
  public static let version = "0.1.0"
}
