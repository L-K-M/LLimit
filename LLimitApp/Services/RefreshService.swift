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
}
