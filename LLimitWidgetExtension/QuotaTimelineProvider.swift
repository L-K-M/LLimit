import Foundation
import WidgetKit
import QuotaCore

struct QuotaEntry: TimelineEntry {
  let date: Date
  let storedSnapshot: DashboardStoredValue<QuotaSnapshot>
  let history: [QuotaSnapshot]
  let refreshIntervalMinutes: Int
  let storedSettings: DashboardStoredValue<AppSettings>

  // Trend/background consumers keep their fallbacks; dashboard reads outcomes.
  var snapshot: QuotaSnapshot? { storedSnapshot.value }
  var settings: AppSettings { storedSettings.value ?? .default }
  var dashboard: DashboardPresentation { DashboardPresentation(settings: storedSettings, snapshot: storedSnapshot) }

  func at(_ date: Date) -> QuotaEntry {
    QuotaEntry(date: date, storedSnapshot: storedSnapshot, history: history,
               refreshIntervalMinutes: refreshIntervalMinutes, storedSettings: storedSettings)
  }
}

struct QuotaTimelineProvider: TimelineProvider {
  let includesHistory: Bool

  func placeholder(in context: Context) -> QuotaEntry {
    QuotaEntry(
      date: Date(),
      storedSnapshot: .loaded(SampleSnapshotFactory.make(now: Date())),
      history: includesHistory ? SampleSnapshotFactory.makeHistory(now: Date()) : [],
      refreshIntervalMinutes: 30,
      storedSettings: .loaded(SampleSnapshotFactory.makeSettings())
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
    if context.isPreview {
      completion(
        QuotaEntry(
          date: Date(),
          storedSnapshot: .loaded(SampleSnapshotFactory.make(now: Date())),
          history: includesHistory ? SampleSnapshotFactory.makeHistory(now: Date()) : [],
          refreshIntervalMinutes: 30,
          storedSettings: .loaded(SampleSnapshotFactory.makeSettings())
        )
      )
      return
    }

    completion(makeStoredEntry(now: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
    let now = Date()
    let entry = makeStoredEntry(now: now)
    let refreshMinutes = min(
      max(entry.refreshIntervalMinutes, AppSettings.refreshIntervalRange.lowerBound),
      AppSettings.refreshIntervalRange.upperBound
    )
    let refreshIntervalSeconds = TimeInterval(refreshMinutes * 60)
    let nextRefreshDate = now.addingTimeInterval(refreshIntervalSeconds)
    let dates = includesHistory ? [now] : DashboardTimeline.entryDates(snapshot: entry.snapshot,
      accounts: entry.settings.accounts, now: now, refreshIntervalMinutes: refreshMinutes)
    completion(Timeline(entries: dates.map { entry.at($0) }, policy: .after(nextRefreshDate)))
  }

  private func makeStoredEntry(now: Date) -> QuotaEntry {
    let storedSettings = loadSettings()
    let storedSnapshot = loadSnapshot()
    let settings = storedSettings.value ?? .default
    let history = includesHistory
      ? loadHistory(windowDays: max(1, settings.widgetVisibility.trendHistoryDays), fallbackSnapshot: storedSnapshot.value)
      : []
    let refreshInterval = settings.refreshIntervalMinutes
    return QuotaEntry(
      date: now,
      storedSnapshot: storedSnapshot,
      history: history,
      refreshIntervalMinutes: refreshInterval,
      storedSettings: storedSettings
    )
  }

  private func loadSnapshot() -> DashboardStoredValue<QuotaSnapshot> {
    do {
      let fileURL = try SharedPaths.snapshotFileURL()
      let store = SnapshotStore(fileURL: fileURL, appGroupIdentifier: SharedConstants.appGroupIdentifier)
      guard let snapshot = try store.load(policy: .preserve) else { return .missing }
      return .loaded(snapshot)
    } catch {
      print("[LLimit Widget] Failed to load snapshot: \(error)")
      return .unavailable
    }
  }

  private func loadSettings() -> DashboardStoredValue<AppSettings> {
    do {
      let settingsURL = try SharedPaths.settingsFileURL()
      guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .missing }
      let store = SettingsStore(fileURL: settingsURL)
      return .loaded(try store.load(policy: .preserve))
    } catch {
      print("[LLimit Widget] Failed to load settings: \(error)")
      return .unavailable
    }
  }

  private func loadHistory(windowDays: Int, fallbackSnapshot: QuotaSnapshot?) -> [QuotaSnapshot] {
    do {
      let fileURL = try SharedPaths.historyFileURL()
      let store = QuotaHistoryStore(fileURL: fileURL)
      // Only keep the trend window (plus a one-day buffer) so a large history file
      // can't push the widget extension over its memory budget.
      let history = try store.loadRecent(days: windowDays + 1)

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
  static func makeSettings() -> AppSettings {
    AppSettings(
      accounts: [
        ProviderAccount(id: QuotaProvider.anthropic.rawValue, provider: .anthropic),
        ProviderAccount(id: QuotaProvider.openAI.rawValue, provider: .openAI),
        ProviderAccount(id: QuotaProvider.zhipu.rawValue, provider: .zhipu),
        ProviderAccount(id: QuotaProvider.kimi.rawValue, provider: .kimi),
        ProviderAccount(id: QuotaProvider.googleAntigravity.rawValue, provider: .googleAntigravity),
        ProviderAccount(id: QuotaProvider.gitHubCopilot.rawValue, provider: .gitHubCopilot)
      ]
    )
  }

  static func make(now: Date) -> QuotaSnapshot {
    QuotaSnapshot(
      generatedAt: now,
      providers: [
        ProviderUsage(
          provider: .anthropic,
          title: "Claude",
          subtitle: nil,
          metrics: [
            UsageMetric(id: "five_hour", label: "5-hour limit", remainingPercent: 64, resetIn: "2h 5m"),
            UsageMetric(id: "seven_day", label: "Weekly limit", remainingPercent: 48, resetIn: "3d 6h")
          ],
          maxUsagePercent: 52,
          fetchedAt: now
        ),
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
          provider: .kimi,
          title: "Kimi",
          subtitle: "Kimi for Coding",
          metrics: [
            UsageMetric(
              id: "window-5-hour",
              label: "5-hour limit",
              remainingPercent: 69,
              usedDisplay: "62",
              totalDisplay: "200",
              resetIn: "3h 12m"
            ),
            UsageMetric(
              id: "plan-weekly",
              label: "Weekly limit",
              remainingPercent: 74,
              usedDisplay: "532",
              totalDisplay: "2048",
              resetIn: "4d 2h"
            )
          ],
          maxUsagePercent: 31,
          fetchedAt: now
        ),
        ProviderUsage(
          provider: .googleAntigravity,
          title: "Google Antigravity",
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
          title: "Google Antigravity",
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
