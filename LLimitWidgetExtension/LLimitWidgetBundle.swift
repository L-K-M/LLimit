import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@main
struct LLimitWidgetBundle: WidgetBundle {
  var body: some Widget {
    LLimitWidget()
    QuotaTrendChartWidget()
    ProviderQuotaWidget()
    StaticRegistrationProbeWidget()
    AppIntentRegistrationProbeWidget()
  }
}

private struct RegistrationProbeEntry: TimelineEntry {
  let date: Date
}

private struct StaticRegistrationProbeProvider: TimelineProvider {
  func placeholder(in context: Context) -> RegistrationProbeEntry {
    RegistrationProbeEntry(date: Date())
  }

  func getSnapshot(in context: Context, completion: @escaping (RegistrationProbeEntry) -> Void) {
    completion(RegistrationProbeEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RegistrationProbeEntry>) -> Void) {
    completion(Timeline(entries: [RegistrationProbeEntry(date: Date())], policy: .never))
  }
}

private struct StaticRegistrationProbeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "ch.lkmc.llimit.widget.registration-probe.static",
      provider: StaticRegistrationProbeProvider()
    ) { _ in
      RegistrationProbeView(label: "Static")
        .containerBackground(for: .widget) { Color.clear }
    }
    .configurationDisplayName("Static Registration Probe")
    .description("Temporary WidgetKit descriptor diagnostic.")
    .supportedFamilies([.systemSmall])
  }
}

struct RegistrationProbeIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Registration Probe"
  static let description = IntentDescription("Temporary App Intent descriptor diagnostic.")
  static let isDiscoverable = false

  init() {}
}

private struct AppIntentRegistrationProbeProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> RegistrationProbeEntry {
    RegistrationProbeEntry(date: Date())
  }

  func snapshot(for configuration: RegistrationProbeIntent, in context: Context) async -> RegistrationProbeEntry {
    RegistrationProbeEntry(date: Date())
  }

  func timeline(
    for configuration: RegistrationProbeIntent,
    in context: Context
  ) async -> Timeline<RegistrationProbeEntry> {
    Timeline(entries: [RegistrationProbeEntry(date: Date())], policy: .never)
  }
}

private struct AppIntentRegistrationProbeWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: "ch.lkmc.llimit.widget.registration-probe.app-intent",
      intent: RegistrationProbeIntent.self,
      provider: AppIntentRegistrationProbeProvider()
    ) { _ in
      RegistrationProbeView(label: "App Intent")
        .containerBackground(for: .widget) { Color.clear }
    }
    .configurationDisplayName("App Intent Registration Probe")
    .description("Temporary WidgetKit App Intent descriptor diagnostic.")
    .supportedFamilies([.systemSmall])
  }
}

private struct RegistrationProbeView: View {
  let label: String

  var body: some View {
    VStack {
      Image(systemName: "stethoscope")
      Text(label)
    }
  }
}
