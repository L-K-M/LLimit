import XCTest
@testable import QuotaCore
@testable import LLimitdCore

final class HistoryExporterTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func history() -> [QuotaSnapshot] {
    [
      QuotaSnapshot(
        generatedAt: base,
        providers: [
          ProviderUsage(
            accountID: "acct-1",
            provider: .anthropic,
            title: "Claude, Work",
            metrics: [
              UsageMetric(id: "five-hour", label: "5-hour limit", remainingPercent: 84,
                          resetAt: base.addingTimeInterval(3_600)),
              UsageMetric(id: "weekly", label: "Weekly", remainingPercent: 62),
            ],
            fetchedAt: base
          )
        ],
        failures: []
      )
    ]
  }

  func testCSVHasHeaderAndMetricRows() {
    let csv = HistoryExporter.csv(history: history())
    let lines = csv.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.first, "generatedAt,account_id,provider,account,metric,label,remaining_percent,remaining_amount,reset_at")
    XCTAssertEqual(lines.count, 3) // header + two metrics
    // The title contains a comma and must be quoted.
    XCTAssertTrue(lines[1].contains("\"Claude, Work\""))
    XCTAssertTrue(lines[1].contains(",84,"))
  }

  func testCSVQuotesCarriageReturn() {
    var snapshot = history()[0]
    snapshot.providers[0].title = "line1\rline2"
    let csv = HistoryExporter.csv(history: [snapshot])
    // An embedded \r must be quoted so a row stays on one line.
    XCTAssertTrue(csv.contains("\"line1\rline2\""))
  }

  func testCSVNeutralizesFormulaLeadingCharacters() {
    var snapshot = history()[0]
    snapshot.providers[0].title = "=cmd|' /C calc'!A0"
    var csv = HistoryExporter.csv(history: [snapshot])
    XCTAssertTrue(csv.contains("'=cmd|' /C calc'!A0"))
    snapshot.providers[0].title = "@SUM(1)"
    csv = HistoryExporter.csv(history: [snapshot])
    XCTAssertTrue(csv.contains("'@SUM(1)"))
  }

  func testCSVNeutralizesWhitespaceMaskedFormulas() {
    var snapshot = history()[0]
    snapshot.providers[0].title = "\t=1+1"
    var csv = HistoryExporter.csv(history: [snapshot])
    XCTAssertTrue(csv.contains("'\t=1+1"))
    snapshot.providers[0].title = "\r@SUM(1)"
    csv = HistoryExporter.csv(history: [snapshot])
    XCTAssertTrue(csv.contains("\"'\r@SUM(1)\""))
    snapshot.providers[0].title = "\n=1+1"
    csv = HistoryExporter.csv(history: [snapshot])
    XCTAssertTrue(csv.contains("\"'\n=1+1\""))
  }

  func testJSONRoundTrips() throws {
    let json = try HistoryExporter.json(history: history())
    let data = try XCTUnwrap(json.data(using: .utf8))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([QuotaSnapshot].self, from: data)
    XCTAssertEqual(decoded.count, 1)
    XCTAssertEqual(decoded[0].providers[0].metrics[0].remainingPercent, 84)
  }
}
