import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class HistoryExporterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private func snapshot(_ title: String) -> QuotaSnapshot {
    .init(generatedAt: now, providers: [.init(accountID: "work", provider: .anthropic, title: title,
      metrics: [.init(id: "weekly", label: "Weekly", remainingPercent: 62)], fetchedAt: now)], failures: [], refreshIntervalMinutes: 30)
  }

  func testCSVHeaderQuotingAndFormulaInjectionHardening() {
    let csv = HistoryExporter.csv(history: [snapshot("Claude, \"Work\"")])
    XCTAssertTrue(csv.hasPrefix("generatedAt,account_id,provider,account,metric,label,remaining_percent,remaining_amount,reset_at\n"))
    XCTAssertTrue(csv.contains("\"Claude, \"\"Work\"\"\""))
    for title in ["=1+1", "+1+1", "-1+1", "@SUM(1)", "\t=1+1", "\r@SUM(1)", "\n=1+1", "   =1+1", "\u{00A0}@SUM(1)"] {
      XCTAssertTrue(HistoryExporter.csv(history: [snapshot(title)]).contains("'" + title), title)
    }
    XCTAssertTrue(HistoryExporter.csv(history: [snapshot("line1\rline2")]).contains("\"line1\rline2\""))
  }

  func testJSONRoundTripAndCaseInsensitiveFormat() throws {
    let history = [snapshot("Work")]
    let json = try HistoryExporter.json(history: history)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode([QuotaSnapshot].self, from: Data(json.utf8)), history)
    XCTAssertEqual(try ExportOptions.parse(["--format", "CSV", "--days", "3"]).format, .csv)
    for args in [["--format", "xml"], ["--days", "0"], ["--days"], ["--bogus"]] { XCTAssertThrowsError(try ExportOptions.parse(args)) }
  }
}
