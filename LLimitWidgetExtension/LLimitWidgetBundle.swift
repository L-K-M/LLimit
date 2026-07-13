import WidgetKit
import SwiftUI

@main
struct LLimitWidgetBundle: WidgetBundle {
  var body: some Widget {
    ProviderQuotaWidget()
    LLimitWidget()
    QuotaTrendChartWidget()
  }
}
