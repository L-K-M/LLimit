import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class JunieAllowanceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_368_000)
  // Inert sentinel consumed only by the injected HTTP fixture below.
  private let fixtureKey = "quota-fixture"

  func testEquivalentAllowanceFormattingDoesNotRestartHistory() {
    for text in ["35", "35.0", "35.00", " 35 \n", "3.5e1", "+35"] {
      XCTAssertFalse(JunieCreditAllowance.hasChanged(from: "35", to: text))
    }
    XCTAssertFalse(JunieCreditAllowance.hasChanged(from: nil, to: " \n"))
    XCTAssertFalse(JunieCreditAllowance.hasChanged(from: "0", to: "-0.0"))
  }

  func testDistinctAllowanceBasesStillRestartHistory() {
    for (previous, updated) in [("35", "70"), ("35", "0"), ("", "0"), ("", "35"), ("35", "NaN"), ("NaN", "35")] {
      XCTAssertTrue(JunieCreditAllowance.hasChanged(from: previous, to: updated))
    }
  }

  func testUltimateBalanceDrivesMonthlyRingsGraphAndTrend() async throws {
    let first = try await fetch(balance: 17.5)
    let metric = try XCTUnwrap(first.metrics.first)
    XCTAssertEqual(metric.remainingAmount, 17.5)
    XCTAssertEqual(metric.remainingPercent, 50)
    XCTAssertEqual(metric.usedDisplay, "17.5 credits")
    XCTAssertEqual(metric.totalDisplay, "35 credits")
    XCTAssertEqual(first.maxUsagePercent, 50)
    XCTAssertEqual(defaultRingMetrics(for: first).map(\.id), ["credit-balance"])
    XCTAssertEqual(primaryLimitSlot(for: first.metrics), LimitSeriesSlot(kind: .monthly))
    XCTAssertNil(metric.estimatedTotal)
    XCTAssertFalse(metric.isPercentageEstimated)
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertNil(QuotaPace(metric: metric, provider: .junie, fetchedAt: now, now: now))

    let second = try await fetch(balance: 14, at: now.addingTimeInterval(900))
    let snapshots = [first, second].map { QuotaSnapshot(generatedAt: $0.fetchedAt, providers: [$0], failures: []) }
    let account = ProviderAccount(id: "junie", provider: .junie)
    let bars = MenuBarGraph.bars(snapshot: snapshots[0], accounts: [account], now: now, staleAfter: 3600)
    XCTAssertEqual(bars.first?.level, .remaining(percent: 50, isEstimated: false))
    let chart = TrendSeriesBuilder.build(snapshots: snapshots, latest: snapshots.last,
      settings: AppSettings(accounts: [account]), now: second.fetchedAt)
    let line = try XCTUnwrap(chart.accounts.first?.series.first)
    XCTAssertEqual(line.slot.kind, .monthly)
    XCTAssertEqual(line.samples.map(\.remainingPercent), [50, 40])
  }

  func testAllowanceOverrideSupportsOtherPlansAndUSDAtOneCreditPerDollar() async throws {
    for unit in ["AI_CREDITS", "USD"] {
      let usage = try await fetch(balance: 17.5, allowance: "70", unit: unit)
      let metric = try XCTUnwrap(usage.metrics.first)
      XCTAssertEqual(metric.remainingPercent, 25)
      XCTAssertEqual(metric.totalDisplay, unit == "USD" ? "70 USD" : "70 credits")
      XCTAssertTrue(try XCTUnwrap(metric.detail).contains("configured allowance"))
    }
    let pro = try await fetch(balance: 5, allowance: "10", license: "AIP")
    XCTAssertEqual(pro.metrics.first?.remainingPercent, 50)
    let unconfiguredPro = try await fetch(balance: 5, license: "AIP")
    let unknown = try await fetch(balance: 5, license: "unknown")
    XCTAssertNil(unconfiguredPro.metrics.first?.remainingPercent)
    XCTAssertNil(unknown.metrics.first?.remainingPercent)
  }

  func testZeroDisablesPercentageWithoutLosingBalance() async throws {
    let usage = try await fetch(balance: 17.5, allowance: "0")
    XCTAssertEqual(usage.metrics.first?.remainingAmount, 17.5)
    XCTAssertEqual(usage.metrics.first?.label, "Credit balance")
    XCTAssertNil(usage.metrics.first?.remainingPercent)
    XCTAssertNil(usage.metrics.first?.totalDisplay)
    XCTAssertNil(usage.maxUsagePercent)
    XCTAssertTrue(defaultRingMetrics(for: usage).isEmpty)
  }

  func testClampsOnlyPercentageAndWarnsUsingRealBalance() async throws {
    for (balance, percent, warning) in [
      (70.0, 100, nil), (35.0, 100, nil), (7.0, 20, "Low JetBrains AI balance"),
      (0.01, 0, "Low JetBrains AI balance"), (0.0, 0, "No JetBrains AI balance left"),
      (-2.5, 0, "No JetBrains AI balance left")
    ] {
      let usage = try await fetch(balance: balance)
      XCTAssertEqual(usage.metrics.first?.remainingAmount, balance)
      XCTAssertEqual(usage.metrics.first?.remainingPercent, percent)
      XCTAssertEqual(usage.maxUsagePercent, 100 - percent)
      XCTAssertEqual(usage.warning, warning)
    }
    let toppedUp = try await fetch(balance: 70)
    XCTAssertEqual(toppedUp.metrics.first?.usageLine, "70 credits / 35 credits")
    XCTAssertTrue(try XCTUnwrap(toppedUp.metrics.first?.detail).contains("Top-ups"))
  }

  func testRejectsInvalidAllowanceBeforeNetworking() async {
    for value in ["-1", "NaN", "Infinity", "1e999", "35 credits", "fixture-invalid"] {
      do {
        _ = try await JunieQuotaClient(httpClient: JunieAllowanceNoHTTP()).fetchUsage(
          configuration: configuration(allowance: value), now: now)
        XCTFail("Expected invalid allowance")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .notConfigured)
        XCTAssertFalse(error.message.contains("fixture-invalid"))
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testFiniteExtremeValuesDoNotOverflowPercentage() async throws {
    let usage = try await fetch(balance: 1e300, allowance: "1e-300", unit: "USD")
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(usage.metrics.first?.remainingAmount, 1e300)
    let blank = try await fetch(balance: 17.5, allowance: " \n")
    XCTAssertEqual(blank.metrics.first?.remainingPercent, 50)
  }

  func testAllowanceIsOptionalNonsecretAccountConfiguration() throws {
    let descriptor = try XCTUnwrap(QuotaProvider.junie.credentialFields.first { $0.key == CredentialField.junieCreditAllowance })
    XCTAssertFalse(descriptor.isRequired)
    XCTAssertFalse(descriptor.isSecret)
    XCTAssertTrue(QuotaProvider.junie.hasRequiredCredentials(configuration().credentials))
    let account = ProviderAccount(provider: .junie, credentials: configuration(allowance: "35").credentials)
    let settings = AppSettings(accounts: [account])
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.accounts.first?.credentials[CredentialField.junieCreditAllowance], "35")
    XCTAssertTrue(settings.redactedCredentials().accounts.allSatisfy { $0.credentials.isEmpty })
  }

  private func configuration(allowance: String? = nil) -> ProviderRuntimeConfiguration {
    var credentials = [CredentialField.junieAPIKey: fixtureKey]
    if let allowance { credentials[CredentialField.junieCreditAllowance] = allowance }
    return ProviderRuntimeConfiguration(accountID: "junie", provider: .junie,
      displayName: "Ultimate", isEnabled: true, credentials: credentials)
  }

  private func fetch(balance: Double, allowance: String? = nil, unit: String = "AI_CREDITS",
                     license: String = "AIPU", at date: Date? = nil) async throws -> ProviderUsage {
    try await JunieQuotaClient(httpClient: JunieAllowanceHTTP(balance: balance, unit: unit, license: license)).fetchUsage(
      configuration: configuration(allowance: allowance),
      now: date ?? now
    )
  }
}

private struct JunieAllowanceHTTP: HTTPClient {
  let balance: Double
  let unit: String
  let license: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let data = try JSONSerialization.data(withJSONObject: [
      "active": true, "licenseType": license, "balanceUnit": unit, "balanceLeft": unit == "USD" ? balance : balance * 100_000
    ])
    let url = try XCTUnwrap(request.url)
    return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}

private struct JunieAllowanceNoHTTP: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("Invalid configuration must not make a request")
    throw URLError(.badURL)
  }
}
