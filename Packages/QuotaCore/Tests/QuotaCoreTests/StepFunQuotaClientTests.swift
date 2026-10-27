import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunQuotaClientTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let fixtureToken = "fixture-token"
  private let fixtureWebID = "fixture-device"

  private func configuration(token: String? = "fixture-token", webID: String? = "fixture-device") -> ProviderRuntimeConfiguration {
    var creds: [String: String] = [:]
    if let token { creds[CredentialField.stepFunSessionToken] = token }
    if let webID { creds[CredentialField.stepFunWebID] = webID }
    return ProviderRuntimeConfiguration(
      accountID: "stepfun-personal", provider: .stepFun, displayName: "StepFun",
      isEnabled: true, credentials: creds
    )
  }

  // MARK: - Valid subscription credit response (protobuf JSON, snake_case)

  func testDecodesSubscriptionCreditLeftRateAsMonthlyPercent() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"subscription_credit_reset_time":"1700083200"}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.accountID, "stepfun-personal")
    XCTAssertEqual(usage.provider, .stepFun)
    XCTAssertEqual(usage.title, "StepFun")

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.id, "monthly-credits")
    XCTAssertEqual(metric.label, "Monthly plan credits")
    XCTAssertEqual(metric.remainingPercent, 75)
    // Reset time is preserved but no windowSeconds is invented
    XCTAssertNotNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["monthly-credits"])
    XCTAssertEqual(QuotaWindowKind.classify(metricID: metric.id, label: metric.label), .monthly)
  }

  // MARK: - CamelCase variant

  func testDecodesCamelCaseSubscriptionFields() async throws {
    let body = #"{"status":"CODE_OK","planFamily":2,"planCreditRateLimit":{"subscriptionCreditLeftRate":0.75,"subscriptionCreditResetTime":"1700083200"}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.id, "monthly-credits")
    XCTAssertEqual(metric.remainingPercent, 75)
  }

  // MARK: - Numeric status code (1 = OK)

  func testDecodesNumericStatusCodeOneAsOK() async throws {
    let body = #"{"status":1,"plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.remainingPercent, 75)
  }

  // MARK: - V3 plan family (3)

  func testDecodesV3PlanFamily() async throws {
    let body = #"{"status":"CODE_OK","plan_family":3,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.6}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.remainingPercent, 60)
  }

  // MARK: - Top-up bucket as separate metric

  func testDecodesTopUpBucketAsSeparateMetric() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"credit_buckets":[{"type":2,"credit_total":400,"credit_residual":100,"expire_at":"1800000000"}]}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.count, 2)

    let sub = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(sub.remainingPercent, 75)

    let topup = try XCTUnwrap(usage.metrics.first { $0.id == "topup-credits" })
    XCTAssertEqual(topup.label, "Top-up credits")
    XCTAssertEqual(topup.remainingPercent, 25)
    XCTAssertEqual(topup.usedDisplay, "300 credits")
    XCTAssertEqual(topup.totalDisplay, "400 credits")
    // expire_at is expiry detail only, not reset or window
    XCTAssertNil(topup.resetAt)
    XCTAssertNil(topup.windowSeconds)
  }

  // MARK: - Top-up fallback when no bucket counts

  func testTopUpCreditLeftRateFallback() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.8,"topup_credit_left_rate":0.5}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let topup = try XCTUnwrap(usage.metrics.first { $0.id == "topup-credits" })
    XCTAssertEqual(topup.remainingPercent, 50)
    // Independent from subscription fraction
    let sub = try XCTUnwrap(usage.metrics.first { $0.id == "monthly-credits" })
    XCTAssertEqual(sub.remainingPercent, 80)
  }

  func testTopUpBucketsUseWeightedTotalsInsteadOfAveragedPercentages() async throws {
    let body = #"{"status":"CODE_OK","plan_family":"PLAN_FAMILY_TOKEN","plan_credit_rate_limit":{"credit_buckets":[{"type":"TYPE_TOPUP","credit_total":"100","credit_residual":"100","expire_at":"1800000000"},{"type":"TYPE_TOPUP","credit_total":"900","credit_residual":"0","expire_at":"1900000000"}]}}"#
    let usage = try await StepFunQuotaClient(httpClient: StepFunHTTPStub(body: body))
      .fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(usage.metrics.count, 1)
    XCTAssertEqual(metric.id, "topup-credits")
    XCTAssertEqual(metric.remainingPercent, 10)
    XCTAssertEqual(metric.remainingAmount, 100)
    XCTAssertEqual(metric.usedDisplay, "900 credits")
    XCTAssertEqual(metric.totalDisplay, "1000 credits")
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
  }

  func testExpiredTopUpsCannotBeRevivedByAggregateFraction() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"topup_credit_left_rate":0.99,"credit_buckets":[{"type":2,"credit_total":"100","credit_residual":"100","expire_at":"1699999999"},{"type":2,"credit_total":"900","credit_residual":"900","expire_at":"1700000000"}]}}"#
    let usage = try await StepFunQuotaClient(httpClient: StepFunHTTPStub(body: body))
      .fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.map(\.id), ["monthly-credits"])
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 75)
  }

  func testOmittedProtobufZerosRemainExhaustedWhenQuotaIsEstablished() async throws {
    let creditBody = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_reset_time":"1700083200","credit_buckets":[{"type":2,"credit_total":"400","expire_at":"1800000000"}]}}"#
    let credits = try await StepFunQuotaClient(httpClient: StepFunHTTPStub(body: creditBody))
      .fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(credits.metrics.map(\.id), ["monthly-credits", "topup-credits"])
    XCTAssertEqual(credits.metrics.map(\.remainingPercent), [0, 0])
    XCTAssertEqual(credits.metrics[0].resetAt, Date(timeIntervalSince1970: 1_700_083_200))
    XCTAssertNil(credits.metrics[0].windowSeconds)
    XCTAssertEqual(credits.metrics[1].remainingAmount, 0)
    XCTAssertEqual(credits.metrics[1].usedDisplay, "400 credits")
    XCTAssertEqual(credits.metrics[1].totalDisplay, "400 credits")

    let legacyBody = #"{"status":"CODE_OK","five_hour_usage_reset_time":"1700018000","weekly_usage_reset_time":"1700604800"}"#
    let legacy = try await StepFunQuotaClient(httpClient: StepFunHTTPStub(body: legacyBody))
      .fetchUsage(configuration: configuration(), now: now)
    XCTAssertEqual(legacy.metrics.map(\.id), ["five-hour", "weekly"])
    XCTAssertEqual(legacy.metrics.map(\.remainingPercent), [0, 0])
  }

  func testSubscriptionFractionOverridesContradictoryBucketCounts() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"credit_buckets":[{"type":1,"credit_total":"100","credit_residual":"10"}]}}"#
    let usage = try await StepFunQuotaClient(httpClient: StepFunHTTPStub(body: body))
      .fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.id, "monthly-credits")
    XCTAssertEqual(metric.remainingPercent, 75)
    XCTAssertNil(metric.remainingAmount)
    XCTAssertNil(metric.usedDisplay)
    XCTAssertNil(metric.totalDisplay)
  }

  func testOmittedSubscriptionFractionWithResetOverridesContradictoryBucketCounts() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_reset_time":"1700083200","credit_buckets":[{"type":1,"credit_total":"100","credit_residual":"25"}]}}"#
    let usage = try await StepFunQuotaClient(httpClient: StepFunHTTPStub(body: body))
      .fetchUsage(configuration: configuration(), now: now)

    // Protobuf omits a zero float; a reported subscription reset establishes
    // the exhausted subscription even if optional bucket detail disagrees.
    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.remainingPercent, 0)
    XCTAssertNil(metric.usedDisplay)
    XCTAssertNil(metric.totalDisplay)
  }

  // MARK: - Legacy plan family (1 or absent)

  func testDecodesLegacyFiveHourAndWeeklyMetrics() async throws {
    let body = #"{"status":"CODE_OK","plan_family":1,"five_hour_usage_left_rate":0.5,"weekly_usage_left_rate":0.2}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.count, 2)

    let fiveHour = try XCTUnwrap(usage.metrics.first { $0.id == "five-hour" })
    XCTAssertEqual(fiveHour.remainingPercent, 50)
    XCTAssertEqual(fiveHour.windowSeconds, 18_000)

    let weekly = try XCTUnwrap(usage.metrics.first { $0.id == "weekly" })
    XCTAssertEqual(weekly.remainingPercent, 20)
    XCTAssertEqual(weekly.windowSeconds, 604_800)
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["five-hour", "weekly"])
    XCTAssertEqual(usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) }, [.session, .weekly])
  }

  func testDecodesLegacyMetricsWhenPlanFamilyAbsent() async throws {
    let body = #"{"status":"CODE_OK","five_hour_usage_left_rate":0.5,"weekly_usage_left_rate":0.2}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.metrics.count, 2)
    let fiveHour = try XCTUnwrap(usage.metrics.first { $0.id == "five-hour" })
    XCTAssertEqual(fiveHour.remainingPercent, 50)
  }

  // MARK: - Missing or zero reset yields nil

  func testMissingResetTimeYieldsNilReset() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertNil(metric.resetAt)
  }

  func testZeroResetTimeYieldsNilReset() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"subscription_credit_reset_time":"0"}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertNil(metric.resetAt)
  }

  // MARK: - Credit-family zeros do not create exhausted windows

  func testCreditFamilyZerosInLegacyFieldsDoNotCreateExhaustedWindows() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"five_hour_usage_left_rate":0,"weekly_usage_left_rate":0,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    let usage = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    // Only the subscription metric should appear; zero legacy fields are ignored
    XCTAssertEqual(usage.metrics.count, 1)
    XCTAssertEqual(usage.metrics.first?.id, "monthly-credits")
  }

  // MARK: - HTTP request assertions

  func testSendsPOSTToCorrectEndpoint() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    let req = try XCTUnwrap(requests.first)
    XCTAssertEqual(req.url?.absoluteString, "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")
    XCTAssertEqual(req.httpMethod, "POST")
  }

  func testRequestSetsOasisHeadersAndContentType() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let requests = await http.requests

    let req = try XCTUnwrap(requests.first)
    XCTAssertEqual(req.value(forHTTPHeaderField: "Oasis-Token"), fixtureToken)
    XCTAssertEqual(req.value(forHTTPHeaderField: "Oasis-Webid"), fixtureWebID)
    XCTAssertEqual(req.value(forHTTPHeaderField: "Oasis-Appid"), "20700")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Oasis-Platform"), "web")
    XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
  }

  func testRequestSendsEmptyJSONBody() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let requests = await http.requests

    let req = try XCTUnwrap(requests.first)
    XCTAssertEqual(String(data: req.httpBody ?? Data(), encoding: .utf8), "{}")
  }

  func testRequestHasNoCookieOrAuthorizationHeader() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let requests = await http.requests

    let req = try XCTUnwrap(requests.first)
    XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    XCTAssertFalse(req.httpShouldHandleCookies)
  }

  func testRequestRefusesRedirects() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let policies = await http.redirectPolicies
    XCTAssertEqual(policies.count, 1)
    XCTAssertEqual(policies.first, .refuse)
  }

  // MARK: - JWT token derivation of webID from device_id

  func testDerivesWebIDFromJWTDeviceIDWhenNoExplicitWebID() async throws {
    // A fake JWT with a device_id claim (base64 encoded payload)
    let header = base64urlEncode(#"{"alg":"HS256","typ":"JWT"}"#)
    let payload = base64urlEncode(#"{"device_id":"jwt-device-123","exp":9999999999}"#)
    let jwtToken = "\(header).\(payload).fakesig"

    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    let config = configuration(token: jwtToken, webID: nil)
    _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: config, now: now)

    let requests = await http.requests

    let req = try XCTUnwrap(requests.first)
    XCTAssertEqual(req.value(forHTTPHeaderField: "Oasis-Token"), jwtToken)
    XCTAssertEqual(req.value(forHTTPHeaderField: "Oasis-Webid"), "jwt-device-123")
  }

  // MARK: - Missing and invalid credentials

  func testMissingCredentialsThrowsWithoutHTTP() async {
    let http = StepFunHTTPStub(body: "{}")
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(token: nil), now: now)
      XCTFail("Expected failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testBlankCredentialsThrowWithoutHTTP() async {
    let http = StepFunHTTPStub(body: "{}")
    for blank in ["", "  ", "\n"] {
      do {
        _ = try await StepFunQuotaClient(httpClient: http)
          .fetchUsage(configuration: configuration(token: blank), now: now)
        XCTFail("Expected failure for blank: \(blank.debugDescription)")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .notConfigured)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
      let requests = await http.requests
      XCTAssertTrue(requests.isEmpty, "No HTTP for blank: \(blank.debugDescription)")
    }
  }

  func testInteriorWhitespaceTokenThrowsWithoutHTTP() async {
    let http = StepFunHTTPStub(body: "{}")
    do {
      _ = try await StepFunQuotaClient(httpClient: http)
        .fetchUsage(configuration: configuration(token: "fix ture-token"), now: now)
      XCTFail("Expected failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testControlCharacterTokenThrowsWithoutHTTP() async {
    let http = StepFunHTTPStub(body: "{}")
    do {
      _ = try await StepFunQuotaClient(httpClient: http)
        .fetchUsage(configuration: configuration(token: "fixture\u{0001}token"), now: now)
      XCTFail("Expected failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  // MARK: - HTTP error codes

  func testSanitizes401And403AsAuthFailure() async throws {
    for status in [401, 403] {
      let http = StepFunHTTPStub(body: "", status: status)
      do {
        _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected auth failure for \(status)")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .auth, "Status \(status)")
        XCTAssertFalse(error.message.contains(fixtureToken))
      }
    }
  }

  func testSanitizes302RedirectAsAuthFailure() async throws {
    let http = StepFunHTTPStub(body: "", status: 302)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected auth failure for 302")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
    }
  }

  func testSanitizes429AsRateLimit() async throws {
    let http = StepFunHTTPStub(body: "", status: 429)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
    }
  }

  func testSanitizes500AsAPIFailure() async throws {
    let http = StepFunHTTPStub(body: "", status: 500)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected API failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .api)
    }
  }

  // MARK: - Protobuf status errors

  func testStatusTooManyReturnsRateLimit() async throws {
    let body = #"{"status":"CODE_TOO_MANY"}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
    }
  }

  func testStatusNumericFiveReturnsRateLimit() async throws {
    let body = #"{"status":5}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
    }
  }

  func testOtherErrorStatusReturnsAPIFailure() async throws {
    let body = #"{"status":"CODE_INTERNAL_ERROR"}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected API failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .api)
    }
  }

  // MARK: - Decoding errors

  func testEmptyObjectReturnsDecodingError() async throws {
    let http = StepFunHTTPStub(body: "{}")
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected decoding error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .decoding)
    }
  }

  func testNoUsableQuotaReturnsDecodingError() async throws {
    // Status OK but no quota fields at all
    let body = #"{"status":"CODE_OK"}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected decoding error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .decoding)
    }
  }

  func testMalformedFractionNegativeReturnsDecodingError() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":-0.1}}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected decoding error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .decoding)
    }
  }

  func testMalformedFractionOverOneReturnsDecodingError() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":1.5}}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected decoding error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .decoding)
    }
  }

  func testNegativeTopUpCountsReturnDecodingError() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75,"credit_buckets":[{"type":2,"credit_total":-10,"credit_residual":100}]}}"#
    let http = StepFunHTTPStub(body: body)
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected decoding error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .decoding)
    }
  }

  // MARK: - Error body never leaks credentials

  func testDecodingErrorBodyNeverLeaksToken() async throws {
    let http = StepFunHTTPStub(body: "not-json-at-all")
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected decoding error")
    } catch let error as ProviderClientError {
      XCTAssertFalse(error.message.contains(fixtureToken))
      XCTAssertFalse(error.message.contains(fixtureWebID))
    }
  }

  // MARK: - Cancellation preservation

  func testCancellationErrorRemainsCancellation() async {
    do {
      _ = try await StepFunQuotaClient(httpClient: StepFunFailingHTTP(error: CancellationError()))
        .fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  func testURLErrorCancelledRemainsCancellation() async {
    do {
      _ = try await StepFunQuotaClient(httpClient: StepFunFailingHTTP(error: URLError(.cancelled)))
        .fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  // MARK: - Coordinator integration

  func testLiveCoordinatorRegistersStepFunProvider() async throws {
    let body = #"{"status":"CODE_OK","plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.75}}"#
    let http = StepFunHTTPStub(body: body)
    let snapshot = await QuotaCoordinator.live(httpClient: http).refresh(configurations: [configuration()], now: now)
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.count, 1)
    XCTAssertEqual(snapshot.providers.first?.provider, .stepFun)
  }

  // MARK: - Credentials are redacted

  func testCredentialsAreRedactedInSettings() {
    let account = ProviderAccount(
      provider: .stepFun,
      credentials: [
        CredentialField.stepFunSessionToken: fixtureToken,
        CredentialField.stepFunWebID: fixtureWebID
      ]
    )
    let settings = AppSettings(accounts: [account])
    let redacted = settings.redactedCredentials()
    XCTAssertTrue(redacted.accounts.first?.credentials.isEmpty ?? true)
    for key in [CredentialField.stepFunSessionToken, CredentialField.stepFunWebID] {
      XCTAssertEqual(QuotaProvider.stepFun.credentialFields.first { $0.key == key }?.isSecret, true)
    }
  }

  // MARK: - Helpers

  private func base64urlEncode(_ string: String) -> String {
    return Data(string.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

// MARK: - HTTP Stub

private actor StepFunHTTPStub: HTTPClient {
  private let body: String
  private let status: Int
  private(set) var requests: [URLRequest] = []
  private(set) var redirectPolicies: [HTTPRedirectPolicy] = []

  init(body: String, status: Int = 200) {
    self.body = body
    self.status = status
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let url = request.url!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    redirectPolicies.append(redirects)
    return try await data(for: request)
  }
}

private struct StepFunFailingHTTP: HTTPClient {
  let error: any Error & Sendable

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw error
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    throw error
  }
}
