import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LongcatQuotaTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_600_000)
  private let header = "owned_session_fixture=longcat-secret-fixture"

  private func configuration(id: String = "longcat-personal", header: String? = nil, user: String = "123") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: id, provider: .longcat, displayName: "Personal Longcat", isEnabled: true,
      credentials: [CredentialField.longcatSessionCookies: header ?? self.header, CredentialField.longcatUserID: user,
        CredentialField.longcatSessionOrigin: "https://longcat.ai"])
  }

  private func snapshot(_ amount: Double, previous: QuotaSnapshot? = nil, offset: Double = 0,
                        configuration: ProviderRuntimeConfiguration? = nil) async -> QuotaSnapshot {
    await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: amount)).refresh(
      configurations: [configuration ?? self.configuration()], now: now.addingTimeInterval(offset), previousSnapshot: previous)
  }

  func testAnyIncreaseBecomesOneHundredEvenBelowOldPeak() async throws {
    let first = await snapshot(1_000)
    let spent = await snapshot(400, previous: first, offset: 1)
    let partialRefill = await snapshot(600, previous: spent, offset: 2)
    let spentAgain = await snapshot(300, previous: partialRefill, offset: 3)
    let unchanged = await snapshot(300, previous: spentAgain, offset: 4)
    let exhausted = await snapshot(0, previous: unchanged, offset: 5)
    XCTAssertEqual([first, spent, partialRefill, spentAgain, unchanged, exhausted].map {
      $0.providers.first?.metrics.first?.remainingPercent
    }, [100, 40, 100, 50, 50, 0])
    XCTAssertEqual(partialRefill.providers.first?.metrics.first?.estimatedTotal, 600)
    XCTAssertEqual(exhausted.providers.first?.metrics.first?.estimatedTotal, 600)
    let metric = try XCTUnwrap(spentAgain.providers.first?.metrics.first)
    XCTAssertTrue(metric.isPercentageEstimated)
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .other)
    XCTAssertEqual(defaultRingMetrics(for: spentAgain.providers[0]).map(\.id), ["token-balance"])
    XCTAssertEqual(spentAgain.providers.first?.maxUsagePercent, 50)
  }

  func testReportedAllowanceWinsOverObservedBaselineAndRefills() async throws {
    let baseline = await snapshot(1_000)
    for (amount, percentage) in [(400, 40), (600, 60), (0, 0)] {
      let body = #"{"code":0,"data":{"currentLot":{"lotId":"pack","remainingToken":\#(amount),"totalToken":"1000","consumedRatio":0},"otherLots":[]}}"#
      let result = await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: 0, summary: body)).refresh(
        configurations: [configuration()], now: now.addingTimeInterval(1), previousSnapshot: baseline)
      let metric = try XCTUnwrap(result.providers.first?.metrics.first)
      XCTAssertEqual(metric.remainingPercent, percentage)
      XCTAssertNil(metric.estimatedTotal)
      XCTAssertFalse(metric.isPercentageEstimated)
      XCTAssertFalse(metric.detail?.contains("baseline") == true)
    }
  }

  func testReportedPackRetainsPreciseFractionAndExpiryWithoutReset() async throws {
    let body = #"{"code":0,"data":{"currentLot":{"lotId":"pack","remainingToken":"995960000","totalToken":"1000000000","consumedToken":"4040000","consumedRatio":0.00404,"expireTime":1796256000000},"otherLots":[]}}"#
    let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
      .fetchUsage(configuration: configuration(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.remainingPercent, 100)
    XCTAssertEqual(try XCTUnwrap(metric.remainingFraction), 0.99596, accuracy: 0.0000001)
    XCTAssertEqual(metric.totalAmount, 1_000_000_000)
    XCTAssertEqual(metric.totalDisplay, "1,000,000,000 tokens")
    XCTAssertTrue(metric.detail?.contains("Expires 2026-12-03T00:00:00Z") == true)
    XCTAssertEqual(metric.expiresAt, Date(timeIntervalSince1970: 1_796_256_000))
    XCTAssertNil(metric.expiryDateLabel)
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertNil(QuotaPace(metric: metric, provider: .longcat, fetchedAt: now, now: now))
    let restored = try JSONDecoder().decode(UsageMetric.self, from: JSONEncoder().encode(metric))
    XCTAssertEqual(try XCTUnwrap(restored.remainingFraction), 0.99596, accuracy: 0.0000001)
    XCTAssertEqual(restored.expiresAt, metric.expiresAt)
    XCTAssertFalse(restored.isPercentageEstimated)
  }

  func testOlderSnapshotsRetainPercentageGeometryWithoutReportedTotal() throws {
    let old = Data(#"{"id":"token-balance","label":"Tokens remaining","remainingPercent":75,"isUnlimited":false}"#.utf8)
    let metric = try JSONDecoder().decode(UsageMetric.self, from: old)
    XCTAssertNil(metric.totalAmount)
    XCTAssertNil(metric.expiresAt)
    XCTAssertNil(metric.expiryDateLabel)
    XCTAssertEqual(metric.remainingFraction, 0.75)
  }

  func testLiveConsoleExpiryPreservesUnzonedDateAndServerCountdown() async throws {
    let body = #"{"code":0,"data":{"currentLot":{"lotId":123,"remainingToken":993207730,"totalToken":1000000000,"expireTime":"2026-12-03 01:02:29","remainSeconds":2573499},"otherLots":[]}}"#
    let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
      .fetchUsage(configuration: configuration(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(try XCTUnwrap(metric.remainingFraction), 0.99320773, accuracy: 0.00000001)
    XCTAssertTrue(metric.detail?.contains("Expires 2026-12-03 01:02:29 (29d 18h 51m remaining)") == true)
    XCTAssertNil(metric.expiryDateLabel)
    XCTAssertEqual(metric.expiresAt, now.addingTimeInterval(2_573_499))
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
  }

  func testUnzonedExpiryWithoutCountdownCannotClaimEarliestOrAssumeTimezone() async throws {
    let body = #"{"code":0,"data":{"currentLot":{"lotId":"a","remainingToken":50,"totalToken":100,"expireTime":"2026-12-03 01:02:29"},"otherLots":[{"lotId":"b","remainingToken":50,"totalToken":100,"expireTime":"2026-12-01T00:00:00Z"},{"lotId":"expired","remainingToken":100,"totalToken":100,"expireTime":"2026-12-04 01:02:29","remainSeconds":-1}]}}"#
    let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
      .fetchUsage(configuration: configuration(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.remainingAmount, 100)
    XCTAssertEqual(metric.remainingPercent, 50)
    XCTAssertTrue(metric.detail?.contains("Token-pack expiry: 2026-12-03 01:02:29") == true)
    XCTAssertFalse(metric.detail?.contains("Next") == true)
    XCTAssertEqual(metric.expiryDateLabel, "2026-12-03")
    XCTAssertNil(metric.expiresAt)
  }

  func testGroupedPacksUseSumOfTotalsAndEarliestLiveExpiry() async throws {
    let body = #"{"code":0,"data":{"currentLot":{"lotId":"a","remainingToken":20,"totalToken":100,"expireTime":"2026-12-03T00:00:00Z"},"otherLots":[{"lotId":"b","remainingToken":280,"totalToken":300,"expireTime":"2026-12-01T00:00:00Z"},{"lotId":"expired","remainingToken":100,"totalToken":100,"expireTime":"2020-01-01T00:00:00Z"},{"lotId":"inactive","status":"EXPIRED","remainingToken":100,"totalToken":100}]}}"#
    let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
      .fetchUsage(configuration: configuration(), now: now)
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.remainingAmount, 300)
    XCTAssertEqual(metric.remainingPercent, 75)
    XCTAssertEqual(metric.totalDisplay, "400 tokens")
    XCTAssertTrue(metric.detail?.contains("Next token-pack expiry: 2026-12-01T00:00:00Z") == true)
    XCTAssertEqual(metric.expiresAt, Date(timeIntervalSince1970: 1_796_083_200))
    XCTAssertNil(metric.expiryDateLabel)
  }

  func testPartiallyMissingTotalsKeepWholeScopeOnHighTideFallback() async throws {
    let body = #"{"code":0,"data":{"currentLot":{"lotId":"a","remainingToken":20,"totalToken":100},"otherLots":[{"lotId":"b","remainingToken":80}]}}"#
    let result = await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: 0, summary: body)).refresh(
      configurations: [configuration()], now: now)
    let metric = try XCTUnwrap(result.providers.first?.metrics.first)
    XCTAssertEqual(metric.remainingAmount, 100)
    XCTAssertEqual(metric.remainingPercent, 100)
    XCTAssertEqual(metric.estimatedTotal, 100)
    XCTAssertNil(metric.totalDisplay)
  }

  func testReportedReadingCannotBecomeAFallbackBaseline() async throws {
    let body = #"{"code":0,"data":{"currentLot":{"lotId":"pack","remainingToken":400,"totalToken":1000},"otherLots":[]}}"#
    let reported = await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: 0, summary: body)).refresh(
      configurations: [configuration()], now: now)
    let fallback = await snapshot(200, previous: reported, offset: 1)
    XCTAssertEqual(fallback.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(fallback.providers.first?.metrics.first?.estimatedTotal, 200)
  }

  func testBaselineSurvivesSnapshotStoreRestartAndFailedRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    let first = await snapshot(1_000)
    try store.save(first)
    let reloaded = try XCTUnwrap(store.load())
    let spent = await snapshot(250, previous: reloaded, offset: 1)
    XCTAssertEqual(spent.providers.first?.metrics.first?.remainingPercent, 25)
    let failure = await QuotaCoordinator.live(httpClient: LongcatHTTP(amount: 0, status: 503)).refresh(
      configurations: [configuration()], now: now.addingTimeInterval(2), previousSnapshot: spent)
    let retained = failure.mergingStaleUsage(from: spent)
    XCTAssertEqual(retained.providers.first?.metrics.first?.estimatedTotal, 1_000)
    XCTAssertEqual(retained.providers.first?.fetchedAt, spent.providers.first?.fetchedAt)
    let recovered = await snapshot(200, previous: retained, offset: 3)
    XCTAssertEqual(recovered.providers.first?.metrics.first?.remainingPercent, 20)
    let encoded = String(decoding: try JSONEncoder().encode(recovered), as: UTF8.self)
    XCTAssertFalse(encoded.contains("longcat-secret-fixture"))
    XCTAssertFalse(encoded.contains("owned_session_fixture"))
  }

  func testDifferentAccountsAndCredentialsStartSeparateBaselines() async throws {
    let first = await snapshot(1_000)
    let otherAccount = await snapshot(250, previous: first, offset: 1, configuration: configuration(id: "work"))
    let replaced = await snapshot(250, previous: first, offset: 1,
      configuration: configuration(header: "owned_session_fixture=replacement-fixture"))
    XCTAssertEqual(otherAccount.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(replaced.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(replaced.providers.first?.metrics.first?.estimatedTotal, 250)
  }

  func testPreviousBalancesStaySeparateWhenProvidersShareAnAccountID() async {
    let config = configuration(id: "shared-id")
    var previous = await snapshot(1_000, configuration: config)
    previous.providers.append(ProviderUsage(accountID: "shared-id", provider: .venice, title: "Venice",
      metrics: [UsageMetric(id: "daily-diem", label: "Daily DIEM remaining", remainingPercent: 50,
        remainingAmount: 5, estimatedTotal: 10)],
      fetchedAt: now.addingTimeInterval(1)))
    let next = await snapshot(500, previous: previous, offset: 2, configuration: config)
    XCTAssertEqual(next.providers.first?.metrics.first?.remainingPercent, 50)
    XCTAssertEqual(next.providers.first?.metrics.first?.estimatedTotal, 1_000)
  }

  func testInitialZeroWaitsForPositiveBaseline() async {
    let zero = await snapshot(0)
    XCTAssertEqual(zero.providers.first?.metrics.first?.remainingAmount, 0)
    XCTAssertNil(zero.providers.first?.metrics.first?.remainingPercent)
    XCTAssertNil(zero.providers.first?.metrics.first?.estimatedTotal)
    let refilled = await snapshot(500, previous: zero, offset: 1)
    XCTAssertEqual(refilled.providers.first?.metrics.first?.remainingPercent, 100)
  }

  func testOlderResponseCannotReplaceBaseline() async {
    let first = await snapshot(1_000)
    let spent = await snapshot(400, previous: first, offset: 2)
    let delayed = await snapshot(600, previous: spent, offset: 1)
    XCTAssertEqual(delayed.providers.first?.metrics.first?.remainingPercent, 40)
    XCTAssertEqual(delayed.providers.first?.metrics.first?.estimatedTotal, 1_000)
    XCTAssertEqual(delayed.providers.first?.metrics.first?.remainingAmount, 400)
  }

  func testClientRequestContractAndManualValidation() async throws {
    let http = LongcatHTTP(amount: 42)
    let saved = try await LongcatQuotaClient(httpClient: http).verifiedManualCredentials(
      header: header + "; _ga=analytics-fixture", now: now)
    XCTAssertEqual(saved[CredentialField.longcatSessionCookies], header)
    XCTAssertEqual(saved[CredentialField.longcatUserID], "123")
    XCTAssertEqual(saved[CredentialField.longcatSessionOrigin], "https://longcat.ai")
    XCTAssertEqual(saved.count, 3)
    let requests = await http.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/user-current", "/api/pay/quota/metering/token-packs/summary"])
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests.last?.httpBody, Data("{}".utf8))
    XCTAssertTrue(requests.allSatisfy { !$0.httpShouldHandleCookies && $0.cachePolicy == .reloadIgnoringLocalCacheData })
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == header })
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
  }

  func testInternationalConsoleRequestsUseOnlyItsOwnOrigin() async throws {
    let http = LongcatHTTP(amount: 42)
    _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    for request in requests {
      XCTAssertEqual(request.url?.host, "longcat.ai")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://longcat.ai")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://longcat.ai/platform/usage")
    }
  }

  func testLegacyManualSessionRequiresReconnectBeforeSendingCookies() async {
    var legacy = configuration()
    legacy.credentials[CredentialField.longcatSessionOrigin] = nil
    let http = LongcatHTTP(amount: 42)
    do {
      _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: legacy, now: now)
      XCTFail("A saved manual header without origin proof must require explicit replacement")
    } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
    catch { XCTFail("Unexpected error") }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testForeignManualOriginsCannotSendCookies() async {
    for origin in ["https://longcat.chat", "http://longcat.ai", "https://longcat.ai.evil.test", "https://evil.test"] {
      var saved = configuration()
      saved.credentials[CredentialField.longcatSessionOrigin] = origin
      let http = LongcatHTTP(amount: 42)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: saved, now: now)
        XCTFail("A different origin must not authorize sending these cookies")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
      catch { XCTFail("Unexpected error") }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testChineseBrowserSessionCannotBeForwardedToInternationalConsole() async {
    var legacy = configuration()
    // Version 46 stored China-scoped cookies. Even a new origin marker cannot
    // authorize widening the serialized cookies' original domain scope.
    legacy.credentials[CredentialField.longcatBrowserSession] = #"[{"name":"owned_session_fixture","value":"longcat-secret-fixture","domain":"longcat.chat","path":"/","secure":true,"httpOnly":true}]"#
    let http = LongcatHTTP(amount: 42)
    do {
      _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: legacy, now: now)
      XCTFail("China-scoped browser cookies must require reconnecting")
    } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
    catch { XCTFail("Unexpected error") }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testFreshInternationalBrowserCanVerifyBeforeIdentityIsSaved() async throws {
    let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "owned_session_fixture", .value: "international-fixture",
      .domain: "longcat.ai", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
    let browser = try LongcatBrowserSession(cookies: [cookie], now: now)
    var candidate = configuration()
    candidate.credentials = [CredentialField.longcatSessionCookies: browser.cookieHeader,
      CredentialField.longcatBrowserSession: try browser.encoded()]
    let http = LongcatHTTP(amount: 42)
    let connection = try await LongcatQuotaClient(httpClient: http).verifiedConnection(configuration: candidate, now: now)
    XCTAssertEqual(connection.userID, "123")
    let saved = try browser.credentials(userID: connection.userID)
    XCTAssertEqual(saved[CredentialField.longcatSessionOrigin], "https://longcat.ai")
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "longcat.ai" })
  }

  func testInternationalBalanceCannotInheritLegacyOriginBaseline() async {
    var legacy = await snapshot(1_000)
    legacy.providers[0].metrics[0].estimateKeyHash = credentialFingerprint("123\n" + header)
    let international = await snapshot(400, previous: legacy, offset: 1)
    XCTAssertEqual(international.providers.first?.metrics.first?.remainingPercent, 100)
    XCTAssertEqual(international.providers.first?.metrics.first?.estimatedTotal, 400)
  }

  func testAnonymousOrWrongIdentityIsRejectedBeforeQuotaRequest() async throws {
    for user in [#"{"loginStatus":0,"userId":null}"#, #"{"loginStatus":1,"userId":"456"}"#] {
      let http = LongcatHTTP(amount: 42, user: user)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Must reject unverified identity")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .auth) }
      let count = await http.requests.count
      XCTAssertEqual(count, 1)
    }
  }

  func testSummaryScopesRemainSeparateAndLotOrderDoesNotChangeMetricIDs() async throws {
    let scope = #"{\"models\":[\"Longcat-2.5\"]}"#
    let current = #"{"lotId":"one","status":"ACTIVE","remainingToken":"100","totalToken":200,"modelScope":"\#(scope)"}"#
    let other = #"{"lotId":"two","status":"ACTIVE","remainingToken":50,"totalToken":100,"modelScope":"\#(scope)"},{"lotId":"all","remainingToken":25,"totalToken":100}"#
    let body = #"{"code":0,"data":{"currentLot":\#(current),"otherLots":[\#(other)]}}"#
    let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
      .fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(usage.metrics.count, 2)
    XCTAssertEqual(usage.metrics.first { $0.id == "token-balance" }?.remainingAmount, 25)
    XCTAssertEqual(usage.metrics.first { $0.id != "token-balance" }?.remainingAmount, 150)
    XCTAssertEqual(usage.metrics.first { $0.id == "token-balance" }?.remainingPercent, 25)
    XCTAssertEqual(usage.metrics.first { $0.id != "token-balance" }?.remainingPercent, 50)
    XCTAssertTrue(usage.metrics.allSatisfy { $0.estimatedTotal == nil })
  }

  func testMissingOrEmptyModelListsMeanAllModels() async throws {
    for scope in ["{}", #"{\"models\":[]}"#] {
      let body = #"{"code":0,"data":{"currentLot":{"lotId":"unscoped","remainingToken":50,"modelScope":"\#(scope)"},"otherLots":[]}}"#
      let usage = try await LongcatQuotaClient(httpClient: LongcatHTTP(amount: 0, summary: body))
        .fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.first?.id, "token-balance")
      XCTAssertEqual(usage.metrics.first?.remainingAmount, 50)
    }
  }

  func testMalformedQuotaCannotPublishFabricatedZero() async throws {
    for data in [
      #"{"currentLot":{"lotId":"a","remainingToken":true},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":-1},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":"NaN"},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":101,"totalToken":100},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":1,"totalToken":-1},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":1,"expireTime":"invalid"},"otherLots":[]}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":3}}"#,
      #"{"currentLot":{"lotId":"a","remainingToken":3},"otherLots":[{"lotId":"a","remainingToken":3}]}"#
    ] {
      let http = LongcatHTTP(amount: 0, summary: #"{"code":0,"data":\#(data)}"#)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Invalid counts must fail")
      } catch let error as ProviderClientError { XCTAssertEqual(error.kind, .decoding) }
    }
  }

  func testLegacyFallbackOnlyForAbsentSummaryAndKeepsAvailableTokens() async throws {
    for missing in [false, true] {
      let http = LongcatHTTP(amount: 80, summary: #"{"code":0,"data":{"currentLot":null,"otherLots":[]}}"#,
        summaryStatus: missing ? 404 : 200)
      let usage = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTAssertEqual(usage.metrics.first?.remainingAmount, 80)
      XCTAssertEqual(usage.metrics.first?.remainingPercent, 8)
      XCTAssertEqual(usage.metrics.first?.totalDisplay, "1,000 tokens")
      let paths = await http.requests.map { $0.url!.path }
      XCTAssertEqual(paths.last, "/api/lc-platform/v1/tokenUsage")
    }
  }

  func testMissingLegacyEndpointIsRequestedOnlyOnceAfterEmptySummary() async {
    let http = LongcatHTTP(amount: 0, summary: #"{"code":0,"data":{"currentLot":null,"otherLots":[]}}"#,
      legacyStatus: 404)
    do {
      _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("An unavailable legacy endpoint must fail the refresh")
    } catch let error as ProviderClientError { XCTAssertEqual(error.statusCode, 404) }
    catch { XCTFail("Unexpected error") }
    let paths = await http.requests.map { $0.url!.path }
    XCTAssertEqual(paths.filter { $0 == "/api/lc-platform/v1/tokenUsage" }.count, 1)
  }

  func testAuthRateLimitsAndAPIFailuresDoNotLeakResponseTextOrFallback() async throws {
    for (status, code, expected) in [(200, 401, QuotaErrorKind.auth), (200, 429, .rateLimit), (429, 0, .rateLimit),
                                    (302, 0, .auth), (503, 0, .api)] {
      let http = LongcatHTTP(amount: 0,
        summary: #"{"code":\#(code),"msg":"longcat-secret-fixture","data":null}"#, summaryStatus: status)
      do {
        _ = try await LongcatQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Must fail closed")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, expected)
        XCTAssertFalse(error.message.contains("longcat-secret-fixture"))
      }
      let count = await http.requests.count
      XCTAssertEqual(count, 2)
    }
  }

  func testFailurePolicyRedactsIndividualCookieValues() async throws {
    let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "owned_session_fixture", .value: "browser-secret-fixture",
      .domain: "longcat.ai", .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
    let browser = try LongcatBrowserSession(cookies: [cookie], now: now)
    let browserConfig = ProviderRuntimeConfiguration(accountID: "browser", provider: .longcat,
      displayName: "Longcat", isEnabled: true, credentials: try browser.credentials(userID: "123"))
    let manualConfig = configuration(header: #"owned_session_fixture="quoted-secret-fixture"; other=second-secret-fixture"#)
    let message = #"browser-secret-fixture "quoted-secret-fixture" quoted-secret-fixture second-secret-fixture"#
    let result = await QuotaCoordinator(clients: [LongcatFailureClient(message: message)]).refresh(
      configurations: [browserConfig, manualConfig], now: now)
    XCTAssertEqual(result.failures.count, 2)
    let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    for secret in ["browser-secret-fixture", "quoted-secret-fixture", "second-secret-fixture"] {
      XCTAssertFalse(json.contains(secret))
    }
    XCTAssertTrue(result.failures.allSatisfy { $0.message.contains("[redacted]") })
  }
}

private struct LongcatFailureClient: QuotaProviderClient {
  let provider: QuotaProvider = .longcat
  let message: String
  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw ProviderClientError(kind: .auth, message: message)
  }
}

private actor LongcatHTTP: HTTPClient {
  let amount: Double
  let user: String
  let summary: String?
  let status: Int
  let summaryStatus: Int
  let legacyStatus: Int
  private(set) var requests: [URLRequest] = []
  init(amount: Double, user: String = #"{"loginStatus":1,"userId":"123","token":"never-publish-fixture"}"#,
       summary: String? = nil, status: Int = 200, summaryStatus: Int = 200, legacyStatus: Int = 200) {
    self.amount = amount; self.user = user; self.summary = summary; self.status = status; self.summaryStatus = summaryStatus
    self.legacyStatus = legacyStatus
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("Session transport must refuse redirects")
    throw URLError(.badURL)
  }
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(redirects, .refuse)
    requests.append(request)
    let body: String
    let httpStatus: Int
    switch request.url!.path {
    case "/api/v1/user-current": body = #"{"code":0,"data":\#(user)}"#; httpStatus = status
    case "/api/pay/quota/metering/token-packs/summary":
      body = summary ?? #"{"code":0,"data":{"currentLot":{"lotId":"fixture-lot","status":"ACTIVE","remainingToken":\#(amount)},"otherLots":[]}}"#
      httpStatus = summaryStatus
    case "/api/lc-platform/v1/tokenUsage":
      body = #"{"code":0,"data":{"usage":{"totalToken":1000,"availableToken":\#(amount),"usedToken":1}}}"#
      httpStatus = legacyStatus
    default: throw URLError(.badURL)
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: httpStatus,
      httpVersion: nil, headerFields: ["Retry-After": "60"])!)
  }
}
