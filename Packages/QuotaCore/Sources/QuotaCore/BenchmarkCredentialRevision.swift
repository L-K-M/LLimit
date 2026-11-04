import Foundation

public struct BenchmarkCredentialRevision: Sendable {
  private var latestRenewal: UUID?
  private var ownershipRevision: UUID?

  public init() {}

  /// Automatic renewal can replace authentication without changing its verified
  /// owner. Explicit edits keep their own revision and invalidate older trials.
  public func ownership(of currentRevision: UUID?) -> UUID? {
    guard let latestRenewal, currentRevision == latestRenewal else { return currentRevision }
    return ownershipRevision
  }

  /// Call only after the renewed credentials have passed same-identity checks.
  public mutating func recordVerifiedRenewal(from previous: UUID?, to next: UUID) {
    ownershipRevision = ownership(of: previous)
    latestRenewal = next
  }
}
