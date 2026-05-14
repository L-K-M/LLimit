import Foundation
import WidgetKit
import QuotaCore

struct QuotaEntry: TimelineEntry {
  let date: Date
  let snapshot: QuotaSnapshot?
  let history: [QuotaSnapshot]
  let refreshIntervalMinutes: Int
  let settings: AppSettings
}

struct QuotaTimelineProvider: TimelineProvider {

  func placeholder(in context: Context) -> QuotaEntry {
    QuotaEntry(
      date: Date(),
      snapshot: SampleSnapshotFactory.make(now: Date()),
      history: SampleSnapshotFactory.makeHistory(now: Date()),
      refreshIntervalMinutes: 30,
      settings: .default
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
    if context.isPreview {
      completion(
        QuotaEntry(
          date: Date(),
          snapshot: SampleSnapshotFactory.make(now: Date()),
          history: SampleSnapshotFactory.makeHistory(now: Date()),
          refreshIntervalMinutes: 30,
          settings: .default
        )
      )
      return
    }

    completion(makeStoredEntry(now: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
    let now = Date()
    let entry = makeStoredEntry(now: now)
    let refreshMinutes = max(15, entry.refreshIntervalMinutes)
    let refreshIntervalSeconds = TimeInterval(refreshMinutes * 60)
    let entrySpacingSeconds: TimeInterval = 5 * 60

    var entries: [QuotaEntry] = []
    var offset: TimeInterval = 0
    while offset < refreshIntervalSeconds {
      let entryDate = now.addingTimeInterval(offset)
      entries.append(QuotaEntry(
        date: entryDate,
        snapshot: entry.snapshot,
        history: entry.history,
        refreshIntervalMinutes: entry.refreshIntervalMinutes,
        settings: entry.settings
      ))
      offset += entrySpacingSeconds
    }

    // Final entry at exactly the next refresh boundary
    let nextRefreshDate = now.addingTimeInterval(refreshIntervalSeconds)
    if let lastEntry = entries.last, lastEntry.date < nextRefreshDate {
      entries.append(QuotaEntry(
        date: nextRefreshDate,
        snapshot: entry.snapshot,
        history: entry.history,
        refreshIntervalMinutes: entry.refreshIntervalMinutes,
        settings: entry.settings
      ))
    }

    completion(Timeline(entries: entries, policy: .atEnd))
  }

  private func makeStoredEntry(now: Date) -> QuotaEntry {
    let settings = loadSettings()
    let snapshot = loadSnapshot()
    let history = loadHistory(fallbackSnapshot: snapshot)
    let refreshInterval = max(15, settings.refreshIntervalMinutes)
    return QuotaEntry(
      date: now,
      snapshot: snapshot,
      history: history,
      refreshIntervalMinutes: refreshInterval,
      settings: settings
    )
  }

  private func loadSnapshot() -> QuotaSnapshot? {
    do {
      let fileURL = try SharedPaths.snapshotFileURL()
      let store = SnapshotStore(fileURL: fileURL, appGroupIdentifier: SharedConstants.appGroupIdentifier)
      return try store.load()
    } catch {
      print("[LLimit Widget] Failed to load snapshot: \(error)")
      return nil
    }
  }

  private func loadSettings() -> AppSettings {
    do {
      let settingsURL = try SharedPaths.settingsFileURL()
      let store = SettingsStore(fileURL: settingsURL)
      return try store.load()
    } catch {
      print("[LLimit Widget] Failed to load settings, using defaults: \(error)")
      return .default
    }
  }

  private func loadHistory(fallbackSnapshot: QuotaSnapshot?) -> [QuotaSnapshot] {
    do {
      let fileURL = try SharedPaths.historyFileURL()
      let store = QuotaHistoryStore(fileURL: fileURL)
      let history = try store.load().sorted { $0.generatedAt < $1.generatedAt }

      if !history.isEmpty {
        return history
      }

      if let fallbackSnapshot {
        return [fallbackSnapshot]
      }
    } catch {
      print("[LLimit Widget] Failed to load history: \(error)")
    }

    if let fallbackSnapshot {
      return [fallbackSnapshot]
    }

    return []
  }
}

private enum SampleSnapshotFactory {
  static func make(now: Date) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          provider: .openAI,
          title: "OpenAI",
          subtitle: "plus",
          metrics: [
            UsageMetric(
              id: "primary",
              label: "3-hour limit",
              remainingPercent: 72,
              usedDisplay: "28",
              totalDisplay: "100",
              resetIn: "1h 42m"
            ),
            UsageMetric(
              id: "secondary",
              label: "7-day limit",
              remainingPercent: 61,
              usedDisplay: "39",
              totalDisplay: "100",
              resetIn: "2d 3h"
            )
          ],
          maxUsagePercent: 39,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .zhipu,
          title: "Zhipu AI",
          subtitle: "Coding Plan",
          metrics: [
            UsageMetric(
              id: "tokens",
              label: "5-hour token limit",
              remainingPercent: 55,
              usedDisplay: "4.5M",
              totalDisplay: "10.0M",
              resetIn: "2h 10m"
            ),
            UsageMetric(
              id: "mcp",
              label: "MCP monthly quota",
              remainingPercent: 81,
              usedDisplay: "19",
              totalDisplay: "100"
            )
          ],
          maxUsagePercent: 45,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .googleAntigravity,
          title: "Google Cloud",
          subtitle: "workspace@example.com",
          metrics: [
            UsageMetric(
              id: "g3-pro",
              label: "G3 Pro",
              remainingPercent: 63,
              resetIn: "10h"
            )
          ],
          maxUsagePercent: 37,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .gitHubCopilot,
          title: "GitHub Copilot",
          subtitle: "pro",
          metrics: [
            UsageMetric(
              id: "premium",
              label: "Premium requests",
              remainingPercent: 58,
              usedDisplay: "126",
              totalDisplay: "300",
              resetIn: "4d 6h"
            )
          ],
          maxUsagePercent: 42,
          fetchedAt: now
        )
      ],
      failures: []
    )
  }

  static func makeHistory(now: Date) -> [QuotaSnapshot] {
    let baseSnapshots = [
      makeSnapshot(now: now.addingTimeInterval(-6 * 86_400), usageOffset: -18),
      makeSnapshot(now: now.addingTimeInterval(-5 * 86_400), usageOffset: -14),
      makeSnapshot(now: now.addingTimeInterval(-4 * 86_400), usageOffset: -11),
      makeSnapshot(now: now.addingTimeInterval(-3 * 86_400), usageOffset: -8),
      makeSnapshot(now: now.addingTimeInterval(-2 * 86_400), usageOffset: -5),
      makeSnapshot(now: now.addingTimeInterval(-86_400), usageOffset: -2),
      makeSnapshot(now: now, usageOffset: 0)
    ]

    return baseSnapshots.sorted { $0.generatedAt < $1.generatedAt }
  }

  private static func makeSnapshot(now: Date, usageOffset: Int) -> QuotaSnapshot {
    let clamp = { (value: Int) in max(0, min(100, value)) }

    return QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          provider: .openAI,
          title: "OpenAI",
          subtitle: "plus",
          metrics: [
            UsageMetric(
              id: "primary",
              label: "3-hour limit",
              remainingPercent: clamp(72 + usageOffset),
              usedDisplay: "28",
              totalDisplay: "100",
              resetIn: "1h 42m"
            ),
            UsageMetric(
              id: "secondary",
              label: "7-day limit",
              remainingPercent: clamp(61 + usageOffset),
              usedDisplay: "39",
              totalDisplay: "100",
              resetIn: "2d 3h"
            )
          ],
          maxUsagePercent: 39,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .zhipu,
          title: "Zhipu AI",
          subtitle: "Coding Plan",
          metrics: [
            UsageMetric(
              id: "tokens",
              label: "5-hour token limit",
              remainingPercent: clamp(55 + usageOffset),
              usedDisplay: "4.5M",
              totalDisplay: "10.0M",
              resetIn: "2h 10m"
            ),
            UsageMetric(
              id: "mcp",
              label: "MCP monthly quota",
              remainingPercent: clamp(81 + usageOffset),
              usedDisplay: "19",
              totalDisplay: "100"
            )
          ],
          maxUsagePercent: 45,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .googleAntigravity,
          title: "Google Cloud",
          subtitle: "workspace@example.com",
          metrics: [
            UsageMetric(
              id: "g3-pro",
              label: "G3 Pro",
              remainingPercent: clamp(63 + usageOffset),
              resetIn: "10h"
            )
          ],
          maxUsagePercent: 37,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .gitHubCopilot,
          title: "GitHub Copilot",
          subtitle: "pro",
          metrics: [
            UsageMetric(
              id: "premium",
              label: "Premium requests",
              remainingPercent: clamp(58 + usageOffset),
              usedDisplay: "126",
              totalDisplay: "300",
              resetIn: "4d 6h"
            )
          ],
          maxUsagePercent: 42,
          fetchedAt: now
        )
      ],
      failures: []
    )
  }
}
