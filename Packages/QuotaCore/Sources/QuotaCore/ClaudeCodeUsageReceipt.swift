import Foundation

/// Records which isolated login supplied a completed usage fetch. A timestamp
/// alone cannot distinguish usage fetched with an account's previous login.
public struct ClaudeCodeUsageReceipt: Equatable, Sendable {
  public let profileID: UUID
  public let fetchedAt: Date

  public init(profileID: UUID, fetchedAt: Date) {
    self.profileID = profileID
    self.fetchedAt = fetchedAt
  }

  public func satisfies(profileID: UUID, since: Date) -> Bool {
    self.profileID == profileID && fetchedAt >= since
  }
}
