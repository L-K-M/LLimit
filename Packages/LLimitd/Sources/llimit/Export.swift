import Foundation
import QuotaCore
import LLimitdCore

func runExport(_ args: [String]) {
  let options: ExportOptions
  do { options = try ExportOptions.parse(args) }
  catch { failUsage(error) }
  do {
    // Export the complete archive, without the widget-oriented loadRecent cap.
    var history = try QuotaHistoryStore(fileURL: LinuxPaths().historyFileURL).load()
    if let days = options.days {
      let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
      history.removeAll { $0.generatedAt < cutoff }
    }
    if history.isEmpty { writeStandardError("llimit: no history recorded; run `llimit refresh` or start the daemon") }
    switch options.format {
    case .csv: print(HistoryExporter.csv(history: history), terminator: "")
    case .json: print(try HistoryExporter.json(history: history))
    }
  } catch { fail("cannot export history") }
}
