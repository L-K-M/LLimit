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
