import WidgetKit
import SwiftUI

@main
struct LLimitWidgetBundle: WidgetBundle {
  var body: some Widget {
    // WidgetBundleBuilder accepts at most ten widgets per block, so the twelve
    // provider tiles live in nested bundles.
    LowerProviderTileBundle().body
    UpperProviderTileBundle().body
    LLimitWidget()
    QuotaTrendChartWidget()
  }
}

private struct LowerProviderTileBundle: WidgetBundle {
  var body: some Widget {
    ProviderTileSlot1Widget()
    ProviderTileSlot2Widget()
    ProviderTileSlot3Widget()
    ProviderTileSlot4Widget()
    ProviderTileSlot5Widget()
    ProviderTileSlot6Widget()
  }
}

private struct UpperProviderTileBundle: WidgetBundle {
  var body: some Widget {
    ProviderTileSlot7Widget()
    ProviderTileSlot8Widget()
    ProviderTileSlot9Widget()
    ProviderTileSlot10Widget()
    ProviderTileSlot11Widget()
    ProviderTileSlot12Widget()
  }
}
