import Foundation
import QuotaCore

struct RefreshService {
  let coordinator: QuotaCoordinator
  let snapshotStore: SnapshotStore

  func refresh(configurations: [ProviderRuntimeConfiguration]) async throws -> QuotaSnapshot {
    // Read the previous snapshot before overwriting it so accounts that fail this cycle
    // can keep showing their last-known usage instead of vanishing from the widgets.
    let previous = try? snapshotStore.load()
    let snapshot = await coordinator.refresh(configurations: configurations)
    let merged = snapshot.mergingStaleUsage(from: previous)
    try snapshotStore.save(merged)
    return merged
  }

  /// Fetches usage without persisting — used to re-fetch a subset of accounts (e.g. an
  /// OpenAI-only retry) that then gets spliced back into the full snapshot.
  func fetch(configurations: [ProviderRuntimeConfiguration]) async -> QuotaSnapshot {
    await coordinator.refresh(configurations: configurations)
  }

  /// Persists an already-assembled snapshot (e.g. after splicing a targeted retry).
  func save(_ snapshot: QuotaSnapshot) throws {
    try snapshotStore.save(snapshot)
  }
}
