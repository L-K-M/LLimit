import Foundation
import QuotaCore

struct RefreshService {
  let coordinator: QuotaCoordinator
  let snapshotStore: SnapshotStore

  func refresh(configurations: [ProviderRuntimeConfiguration], credentialFailures: [ProviderFailure]) async -> QuotaSnapshot {
    // Read the previous snapshot before overwriting it so accounts that fail this cycle
    // can keep showing their last-known usage instead of vanishing from the widgets.
    let previous = try? snapshotStore.load(policy: .recover)
    var snapshot = await coordinator.refresh(configurations: configurations, previousSnapshot: previous)
    snapshot.failures.append(contentsOf: credentialFailures)
    // AppModel validates credentials again before saving: they may have changed
    // while this fetch was in flight.
    return snapshot.mergingStaleUsage(from: previous)
  }

  /// Fetches usage without persisting — used to re-fetch a subset of accounts (e.g. an
  /// OpenAI-only retry) that then gets spliced back into the full snapshot.
  func fetch(configurations: [ProviderRuntimeConfiguration]) async -> QuotaSnapshot {
    // Targeted retries also need prior readings when their fetch is cancelled.
    let previous = try? snapshotStore.load()
    return await coordinator.refresh(configurations: configurations, previousSnapshot: previous)
  }

  /// Persists an already-assembled snapshot (e.g. after splicing a targeted retry).
  func save(_ snapshot: QuotaSnapshot) throws {
    try snapshotStore.save(snapshot)
  }
}
