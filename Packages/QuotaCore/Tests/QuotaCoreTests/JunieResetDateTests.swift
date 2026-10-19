import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class JunieResetDateTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_368_000)
  private let cycleSeconds = 30 * 86_400

  func testDateParsingUsesUTCAndHonorsExplicitOffsets() throws {
    let midnight = Date(timeIntervalSince1970: 1_793_491_200)
    for text in ["2026-11-01", "2026-11-01T00:00:00Z", "2026-11-01T02:30:00+02:30", " 2026-11-01 \n"] {
      XCTAssertEqual(try XCTUnwrap(JunieCreditCycle(anchor: text)).anchor, midnight)
    }
    XCTAssertEqual(try XCTUnwrap(JunieCreditCycle(anchor: "2026-11-01T00:00:00.125Z")).anchor.timeIntervalSince(midnight), 0.125, accuracy: 0.001)
    for text in ["2026-02-29", "2026-13-01", "2026-01-32", "0000-01-01", "2026-11-01T00:00:00+24:00", "2026-11-01T00:00:00Z\nextra"] {
      XCTAssertNil(JunieCreditCycle(anchor: text))
    }
    XCTAssertNotNil(JunieCreditCycle(anchor: "2028-02-29"))
  }

  func testCycleAdvancesAtBoundaryAndUsesFixedDaysAcrossDST() throws {
    let cycle = try XCTUnwrap(JunieCreditCycle(anchor: "2026-10-20T12:00:00+02:00"))
    XCTAssertEqual(cycle.resetAt(after: cycle.anchor.addingTimeInterval(-0.001)), cycle.anchor)
    let next = cycle.resetAt(after: cycle.anchor)
    XCTAssertEqual(next.timeIntervalSince(cycle.anchor), TimeInterval(cycleSeconds))
    XCTAssertEqual(next, try XCTUnwrap(JunieCreditCycle(anchor: "2026-11-19T11:00:00+01:00")).anchor)
    XCTAssertEqual(cycle.resetAt(after: next), next.addingTimeInterval(TimeInterval(cycleSeconds)))
  }

  func testConfiguredResetEnablesCountdownAndThirtyDayPace() async throws {
    let anchor = now.addingTimeInterval(TimeInterval(cycleSeconds / 2))
    let usage = try await fetch(reset: ISO8601DateFormatter().string(from: anchor))
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.resetAt, anchor)
    XCTAssertEqual(metric.resetIn, formatResetCountdown(to: anchor, now: now))
    XCTAssertEqual(metric.windowSeconds, cycleSeconds)
    XCTAssertEqual(metric.remainingPercent, 50)
    XCTAssertTrue(try XCTUnwrap(metric.detail).contains("configured reset"))
    let pace = try XCTUnwrap(QuotaPace(metric: metric, provider: .junie, fetchedAt: now, now: now))
    XCTAssertEqual(pace.elapsedFraction, 0.5, accuracy: 0.000001)
    XCTAssertEqual(pace.delta, 0, accuracy: 0.000001)
  }

  func testPastAnchorAdvancesByThirtyDaysWithoutRefillingBalance() async throws {
    for elapsed in [0, 1, cycleSeconds, cycleSeconds * 3 + 86_400] {
      let anchor = now.addingTimeInterval(-TimeInterval(elapsed))
      let usage = try await fetch(reset: ISO8601DateFormatter().string(from: anchor))
      let metric = try XCTUnwrap(usage.metrics.first)
      let expected = anchor.addingTimeInterval(TimeInterval((elapsed / cycleSeconds + 1) * cycleSeconds))
      XCTAssertEqual(metric.resetAt, expected)
      XCTAssertEqual(metric.remainingAmount, 17.5)
      XCTAssertEqual(metric.remainingPercent, 50)
    }
  }

  func testBlankResetStaysUnknownAndZeroAllowanceKeepsKnownReset() async throws {
    let unknown = try await fetch(reset: " \n")
    XCTAssertNil(unknown.metrics.first?.resetAt)
    XCTAssertNil(unknown.metrics.first?.windowSeconds)
    let anchor = now.addingTimeInterval(86_400)
    let usage = try await fetch(reset: ISO8601DateFormatter().string(from: anchor), allowance: "0")
    XCTAssertEqual(usage.metrics.first?.resetAt, anchor)
    XCTAssertNil(usage.metrics.first?.remainingPercent)
    XCTAssertNil(usage.metrics.first?.windowSeconds)
    XCTAssertNil(QuotaPace(metric: try XCTUnwrap(usage.metrics.first), provider: .junie, fetchedAt: now, now: now))
  }

  func testInvalidResetIsRejectedBeforeNetworkingWithoutReflectingInput() async {
    for value in ["fixture-invalid-date", "2026-02-30", "2026-11-01T00:00:00", "2026-11-01T25:00:00Z", "2026-11-01T00:00:00Z trailing"] {
      do {
        _ = try await JunieQuotaClient(httpClient: ResetMustNotRequest()).fetchUsage(
          configuration: configuration(reset: value), now: now)
        XCTFail("Expected invalid reset date to fail")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .notConfigured)
        XCTAssertFalse(error.message.contains(value))
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testResetSurvivesLoginImportAndIsNonsecretOptionalConfiguration() throws {
    let account = ProviderAccount(provider: .junie, credentials: configuration(reset: "2026-11-01").credentials)
    XCTAssertEqual(account.credentialsForImport([CredentialField.junieAPIKey: "new-fixture"])[CredentialField.junieResetAt], "2026-11-01")
    for reset in ["2026-11-02", ""] {
      XCTAssertEqual(account.credentialsForImport([CredentialField.junieResetAt: reset]), [
        CredentialField.junieCreditAllowance: "35", CredentialField.junieResetAt: reset
      ])
    }
    let field = try XCTUnwrap(QuotaProvider.junie.credentialFields.first { $0.key == CredentialField.junieResetAt })
    XCTAssertFalse(field.isSecret)
    XCTAssertFalse(field.isRequired)
  }

  private func configuration(reset: String, allowance: String = "35") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: "junie", provider: .junie, displayName: "Junie", isEnabled: true,
      credentials: [CredentialField.junieAPIKey: "quota-fixture", CredentialField.junieCreditAllowance: allowance,
                    CredentialField.junieResetAt: reset])
  }

  private func fetch(reset: String, allowance: String = "35") async throws -> ProviderUsage {
    try await JunieQuotaClient(httpClient: ResetBalanceHTTP()).fetchUsage(
      configuration: configuration(reset: reset, allowance: allowance), now: now)
  }
}

private struct ResetBalanceHTTP: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let body = #"{"active":true,"licenseType":"AIPU","balanceUnit":"AI_CREDITS","balanceLeft":1750000}"#
    return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}

private struct ResetMustNotRequest: HTTPClient {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("Invalid reset configuration must not make a request")
    throw URLError(.badURL)
  }
}
