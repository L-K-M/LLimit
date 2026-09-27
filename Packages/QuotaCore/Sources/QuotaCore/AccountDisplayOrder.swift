import Foundation

/// Moves account rows using SwiftUI's pre-removal destination offset. Account
/// values stay intact, and the array remains the only persisted display order.
/// Stale source offsets are ignored; an invalid destination leaves the order alone.
public func reorderedAccounts(
  _ accounts: [ProviderAccount],
  fromOffsets source: IndexSet,
  toOffset destination: Int
) -> [ProviderAccount] {
  guard (0...accounts.count).contains(destination) else { return accounts }
  let validSource = source.filter { accounts.indices.contains($0) }
  guard !validSource.isEmpty else { return accounts }

  let moved = validSource.map { accounts[$0] }
  let sourceSet = Set(validSource)
  var remaining = accounts.enumerated().compactMap { index, account in
    sourceSet.contains(index) ? nil : account
  }
  let insertionIndex = destination - validSource.filter { $0 < destination }.count
  remaining.insert(contentsOf: moved, at: insertionIndex)
  return remaining
}

/// Projects available usage into the enabled accounts' display order. A refresh
/// can return results in a different order, and stale snapshots can still contain
/// disabled or deleted accounts. Legacy provider-keyed usage belongs to an account
/// only when that provider has exactly one account, including disabled accounts.
public func orderedUsageForAccounts(
  _ usages: [ProviderUsage],
  accounts: [ProviderAccount]
) -> [ProviderUsage] {
  let usagesByID = Dictionary(grouping: usages, by: \.accountID)
  let accountsByProvider = Dictionary(grouping: accounts, by: \.provider)

  return accounts.filter(\.isEnabled).compactMap { account in
    let exact = usagesByID[account.id]?.first { $0.provider == account.provider }
    let legacy: ProviderUsage?
    if accountsByProvider[account.provider]?.count == 1 {
      legacy = usagesByID[account.provider.rawValue]?.first { $0.provider == account.provider }
    } else {
      legacy = nil
    }
    guard var usage = exact ?? legacy else { return nil }
    usage.accountID = account.id
    usage.title = account.resolvedDisplayName
    return usage
  }
}
