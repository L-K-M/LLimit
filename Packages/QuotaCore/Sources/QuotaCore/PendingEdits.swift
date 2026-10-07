import Foundation

/// Text typed into Settings fields that is not saved yet, keyed by field. A draft
/// leaves only when a commit consumes it: a rejected draft stays, with the reason,
/// so the field keeps your text and the next commit retries it.
public struct PendingEdits<Key: Hashable> {
  private var drafts: [Key: String] = [:]
  private var rejections: [Key: AccountEditRejection] = [:]

  public init() {}

  public func text(for key: Key) -> String? {
    drafts[key]
  }

  /// Why the draft's last commit was not saved. Kept while you edit, until the
  /// next commit or discard.
  public func rejection(for key: Key) -> AccountEditRejection? {
    rejections[key]
  }

  public mutating func edit(_ key: Key, text: String) {
    drafts[key] = text
  }

  /// Offers the key's draft to `save` once. Returns nil, without calling `save`,
  /// when the field has no draft.
  @discardableResult
  public mutating func commit(
    _ key: Key,
    using save: (Key, String) -> AccountEditOutcome
  ) -> AccountEditOutcome? {
    guard let text = drafts[key] else { return nil }

    let outcome = save(key, text)
    if outcome.consumesDraft {
      drafts[key] = nil
      rejections[key] = nil
    } else if case .rejected(let rejection) = outcome {
      rejections[key] = rejection
    }
    return outcome
  }

  /// Offers every draft once. Rejected drafts stay for the next trigger rather
  /// than being retried here, so a lasting rejection cannot loop.
  public mutating func commitAll(using save: (Key, String) -> AccountEditOutcome) {
    for key in Array(drafts.keys) {
      commit(key, using: save)
    }
  }

  public mutating func discard(where shouldDiscard: (Key) -> Bool) {
    for key in Array(drafts.keys) where shouldDiscard(key) {
      drafts[key] = nil
      rejections[key] = nil
    }
  }
}
