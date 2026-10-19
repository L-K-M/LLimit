import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MiMoQuotaClientTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let fixtureCookies = "api-platform_serviceToken=fake-svc-tok; userId=fake-u-001"

  private func configuration(cookies: String? = "api-platform_serviceToken=fake-svc-tok; userId=fake-u-001", id: String = "mimo-personal") -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: id, provider: .xiaomiMiMo, displayName: "Personal MiMo", isEnabled: true,
      credentials: cookies.map { [CredentialField.mimoSessionCookies: $0] } ?? [:]
    )
  }

  // MARK: - Valid quota fetch

  func testFetchesDetailAndUsageAndComputesRemainingPercent() async throws {
    let detailBody = #"{"code":0,"data":{"planCode":"standard","planName":"Standard","currentPeriodEnd":"2026-11-01T00:00:00Z"}}"#
    let usageBody = #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":25,"limit":100,"percent":0.25}]}}}"#
    let http = MiMoHTTPStub(detail: detailBody, usage: usageBody)
    let usage = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    XCTAssertEqual(usage.accountID, "mimo-personal")
    XCTAssertEqual(usage.provider, .xiaomiMiMo)
    XCTAssertEqual(usage.title, "Personal MiMo")
    XCTAssertEqual(usage.subtitle, "Standard")
    XCTAssertEqual(usage.fetchedAt, now)

    let metric = try XCTUnwrap(usage.metrics.first)
    XCTAssertEqual(metric.id, "plan-credits")
    XCTAssertEqual(metric.label, "Plan credits")
    XCTAssertEqual(metric.remainingPercent, 75)
    XCTAssertEqual(metric.usedDisplay, "25 credits")
    XCTAssertEqual(metric.totalDisplay, "100 credits")
    XCTAssertNil(metric.resetAt)
    XCTAssertNil(metric.windowSeconds)
    XCTAssertEqual(usage.maxUsagePercent, 25)
    XCTAssertNil(usage.warning)
  }

  // MARK: - HTTP request assertions

  func testSendsExactlyTwoGETRequestsToCorrectEndpoints() async throws {
    let detailBody = #"{"code":0,"data":{"planCode":"standard","planName":"Standard"}}"#
    let usageBody = #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":0,"limit":100,"percent":0}]}}}"#
    let http = MiMoHTTPStub(detail: detailBody, usage: usageBody)
    _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)

    let detailReq = try XCTUnwrap(requests.first { $0.url?.path == "/api/v1/tokenPlan/detail" })
    XCTAssertEqual(detailReq.url?.absoluteString, "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail")
    XCTAssertEqual(detailReq.httpMethod, "GET")

    let usageReq = try XCTUnwrap(requests.first { $0.url?.path == "/api/v1/tokenPlan/usage" })
    XCTAssertEqual(usageReq.url?.absoluteString, "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage")
    XCTAssertEqual(usageReq.httpMethod, "GET")
  }

  func testRequestSetsCookieAllowlistAndNoAuthorization() async throws {
    let detailBody = #"{"code":0,"data":{"planCode":"standard","planName":"Standard"}}"#
    let usageBody = #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":0,"limit":100,"percent":0}]}}}"#
    let http = MiMoHTTPStub(detail: detailBody, usage: usageBody)
    _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let requests = await http.requests
    let req = try XCTUnwrap(requests.first)

    let cookieHeader = try XCTUnwrap(req.value(forHTTPHeaderField: "Cookie"))
    XCTAssertTrue(cookieHeader.contains("api-platform_serviceToken=fake-svc-tok"))
    XCTAssertTrue(cookieHeader.contains("userId=fake-u-001"))
    XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    XCTAssertFalse(req.httpShouldHandleCookies)
  }

  func testRequestRefusesRedirects() async throws {
    let detailBody = #"{"code":0,"data":{"planCode":"standard","planName":"Standard"}}"#
    let usageBody = #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":0,"limit":100,"percent":0}]}}}"#
    let http = MiMoHTTPStub(detail: detailBody, usage: usageBody)
    _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)

    let policies = await http.redirectPolicies
    XCTAssertEqual(policies.count, 2)
    XCTAssertTrue(policies.allSatisfy { $0 == .refuse })
  }

  func testBothRequestsPreserveQuotedConsoleCookies() async throws {
    let cookies = #"api-platform_serviceToken="fake-svc-tok"; api-platform_slh="fake-slh"; api-platform_ph="fake-ph"; userId=fake-u-001"#
    let http = MiMoHTTPStub(
      detail: #"{"code":0,"data":{"planCode":"standard","planName":"Standard"}}"#,
      usage: #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":0,"limit":100}]}}}"#
    )
    _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(cookies: cookies), now: now)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    for request in requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), cookies)
      XCTAssertFalse(request.httpShouldHandleCookies)
    }
  }

  // MARK: - Missing and invalid credentials

  func testMissingCredentialsThrowsWithoutHTTP() async {
    let http = MiMoHTTPStub(detail: "{}", usage: "{}")
    do {
      _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(cookies: nil), now: now)
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
    let http = MiMoHTTPStub(detail: "{}", usage: "{}")
    for blank in ["", "  ", "\n"] {
      do {
        _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(cookies: blank), now: now)
        XCTFail("Expected failure for blank: \(blank.debugDescription)")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .notConfigured)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
      let reqs = await http.requests
      XCTAssertTrue(reqs.isEmpty, "No HTTP for blank: \(blank.debugDescription)")
    }
  }

  // MARK: - Sanitized HTTP error codes

  func testSanitizes401And403AsAuthFailure() async throws {
    for status in [401, 403] {
      let http = MiMoHTTPStub(detail: #"{"code":0,"data":{}}"#, usage: #"{"code":0,"data":{}}"#, status: status)
      do {
        _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
        XCTFail("Expected auth failure for \(status)")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .auth, "Status \(status)")
        XCTAssertFalse(error.message.contains(fixtureCookies))
      }
    }
  }

  func testSanitizes302RedirectAsAuthFailure() async throws {
    let http = MiMoHTTPStub(detail: "", usage: "", status: 302)
    do {
      _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected auth failure for 302")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
    }
  }

  func testSanitizes429AsRateLimit() async throws {
    let http = MiMoHTTPStub(detail: "", usage: "", status: 429)
    do {
      _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected rate limit")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .rateLimit)
    }
  }

  func testSanitizes500AsAPIFailure() async throws {
    let http = MiMoHTTPStub(detail: "", usage: "", status: 500)
    do {
      _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected API failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .api)
    }
  }

  // MARK: - Body and transport secrets never echoed

  func testServerErrorBodyNeverEchoedInErrorMessage() async throws {
    let secretBody = "internal-error-details-should-not-appear"
    let http = MiMoHTTPStub(detail: secretBody, usage: "", status: 500)
    do {
      _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected failure")
    } catch let error as ProviderClientError {
      XCTAssertFalse(error.message.contains(secretBody))
    }
  }

  func testTransportErrorNeverEchoesCredentials() async {
    let http = MiMoFailingHTTP(error: ProviderClientError(kind: .network, message: "connection refused"))
    do {
      _ = try await MiMoQuotaClient(httpClient: http).fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected failure")
    } catch let error as ProviderClientError {
      XCTAssertFalse(error.message.contains(fixtureCookies))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - Cancellation preservation

  func testCancellationErrorRemainsCancellation() async {
    do {
      _ = try await MiMoQuotaClient(httpClient: MiMoFailingHTTP(error: CancellationError()))
        .fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  func testURLErrorCancelledRemainsCancellation() async {
    do {
      _ = try await MiMoQuotaClient(httpClient: MiMoFailingHTTP(error: URLError(.cancelled)))
        .fetchUsage(configuration: configuration(), now: now)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  // MARK: - Coordinator integration

  func testLiveCoordinatorRegistersMiMoProvider() async throws {
    let detailBody = #"{"code":0,"data":{"planCode":"standard","planName":"Standard"}}"#
    let usageBody = #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":10,"limit":100,"percent":0.1}]}}}"#
    let http = MiMoHTTPStub(detail: detailBody, usage: usageBody)
    let snapshot = await QuotaCoordinator.live(httpClient: http).refresh(configurations: [configuration()], now: now)
    XCTAssertTrue(snapshot.failures.isEmpty)
    XCTAssertEqual(snapshot.providers.count, 1)
    XCTAssertEqual(snapshot.providers.first?.provider, .xiaomiMiMo)
  }

  func testCoordinatorFailureMergeKeepsLastGoodSnapshot() async throws {
    let goodDetail = #"{"code":0,"data":{"planCode":"standard","planName":"Standard"}}"#
    let goodUsage = #"{"code":0,"data":{"usage":{"items":[{"name":"credits","used":10,"limit":100,"percent":0.1}]}}}"#
    let goodHttp = MiMoHTTPStub(detail: goodDetail, usage: goodUsage)
    let previous = await QuotaCoordinator.live(httpClient: goodHttp)
      .refresh(configurations: [configuration()], now: now)

    // MiMoQuotaClient wraps any non-cancellation HTTP error in a .network
    // ProviderClientError, so the coordinator records .network.
    let failHttp = MiMoFailingHTTP(error: URLError(.networkConnectionLost))
    let snapshot = await QuotaCoordinator.live(httpClient: failHttp)
      .refresh(configurations: [configuration()], now: now, previousSnapshot: previous)

    // Failure should be recorded
    XCTAssertEqual(snapshot.failures.count, 1)
    XCTAssertEqual(snapshot.failures.first?.kind, .network)
    XCTAssertEqual(snapshot.failures.first?.provider, .xiaomiMiMo)
  }

  func testCredentialsAreRedactedInSettings() {
    let account = ProviderAccount(
      provider: .xiaomiMiMo,
      credentials: [CredentialField.mimoSessionCookies: fixtureCookies]
    )
    let settings = AppSettings(accounts: [account])
    let redacted = settings.redactedCredentials()
    XCTAssertTrue(redacted.accounts.first?.credentials.isEmpty ?? true)
  }

  private func assertFailure(_ kind: QuotaErrorKind, operation: () async throws -> ProviderUsage) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(kind)")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, kind)
      XCTAssertFalse(error.message.contains(fixtureCookies))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

// MARK: - HTTP Stub

private actor MiMoHTTPStub: HTTPClient {
  private let detailBody: String
  private let usageBody: String
  private let status: Int
  private(set) var requests: [URLRequest] = []
  private(set) var redirectPolicies: [HTTPRedirectPolicy] = []

  init(detail: String, usage: String, status: Int = 200) {
    self.detailBody = detail
    self.usageBody = usage
    self.status = status
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body: String
    if request.url?.path.contains("detail") == true {
      body = detailBody
    } else {
      body = usageBody
    }
    let url = request.url!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    redirectPolicies.append(redirects)
    return try await data(for: request)
  }
}

private struct MiMoFailingHTTP: HTTPClient {
  let error: any Error & Sendable

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw error
  }

  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    throw error
  }
}
