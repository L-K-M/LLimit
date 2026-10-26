import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepFunQuotaClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let token = "eyJhbGciOiJ9.eyJ1c2VyX2lkIjoidTEiLCJkZXZpY2VfaWQiOiJkZXYtMTIzIn0.sig...eyJhbGciOiJ9.eyJkZXZpY2VfaWQiOiJkZXYtNDU2In0.sig"

  private var configuration: ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "sf",
      provider: .stepfun,
      displayName: "StepFun",
      isEnabled: true,
      credentials: [CredentialField.stepfunOasisToken: token]
    )
  }

  private actor StubHTTP: HTTPClient {
    let bodies: [String: String]
    var requests: [URLRequest] = []

    init(bodies: [String: String]) { self.bodies = bodies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      requests.append(request)
      let action = request.url?.lastPathComponent ?? ""
      let body = Data((bodies[action] ?? #"{"status":1}"#).utf8)
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (body, response)
    }
  }

  /// device_id claim lives in the refresh half ("…dev-456…"), not the access
  /// half — the webid must come from the last JWT segment pair.
  func testWebIDComesFromRefreshHalf() {
    XCTAssertEqual(StepFunQuotaClient.webID(forToken: token), "dev-456")
    XCTAssertEqual(StepFunQuotaClient.webID(forToken: "not-a-jwt"),
                   "c8a1002d2c457e758785a9979832217c7c0b884c")
  }

  func testWindowedPlanMetricsAndRequestShape() async throws {
    let http = StubHTTP(bodies: [
      "QueryStepPlanRateLimit": """
        {"status":1,"five_hour_usage_left_rate":0.9978,"weekly_usage_left_rate":0.6,
         "five_hour_usage_reset_time":"1800018000","weekly_usage_reset_time":"1800500000",
         "plan_family":1}
        """,
      "GetStepPlanStatus": #"{"status":1,"subscription":{"name":"Flash Pro"}}"#
    ])
    let usage = try await StepFunQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)

    XCTAssertEqual(usage.subtitle, "Step Plan Flash Pro")
    XCTAssertEqual(usage.metrics.map(\.id), ["stepfun-five-hour", "stepfun-weekly"])
    XCTAssertEqual(usage.metrics.map(\.remainingPercent), [100, 60])
    XCTAssertEqual(usage.metrics[0].resetAt, Date(timeIntervalSince1970: 1_800_018_000))
    XCTAssertEqual(usage.metrics[0].windowSeconds, 18_000)
    XCTAssertEqual(usage.metrics[1].windowSeconds, 604_800)
    XCTAssertEqual(
      usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) },
      [.session, .weekly])
    XCTAssertEqual(defaultRingMetrics(for: usage).map(\.id), ["stepfun-five-hour", "stepfun-weekly"])

    let requests = await http.requests
    let rateLimit = try XCTUnwrap(requests.first { $0.url?.absoluteString.contains("QueryStepPlanRateLimit") == true })
    XCTAssertEqual(rateLimit.url?.absoluteString,
      "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")
    XCTAssertEqual(rateLimit.value(forHTTPHeaderField: "oasis-webid"), "dev-456")
    XCTAssertEqual(rateLimit.value(forHTTPHeaderField: "Cookie"), "Oasis-Token=\(token); Oasis-Webid=dev-456")
    XCTAssertEqual(rateLimit.value(forHTTPHeaderField: "oasis-appid"), "10300")
    XCTAssertEqual(String(decoding: rateLimit.httpBody ?? Data(), as: UTF8.self), "{}")
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(usage), as: UTF8.self).contains(token))
  }

  func testCreditPlanMetricsFromBuckets() async throws {
    let http = StubHTTP(bodies: [
      "QueryStepPlanRateLimit": """
        {"status":1,"plan_family":2,
         "plan_credit_rate_limit":{
           "subscription_credit_left_rate":0.9,
           "subscription_credit_reset_time":"1802592000",
           "topup_credit_left_rate":0.5,
           "credit_buckets":[
             {"credit_total":"800000000","credit_residual":"720000000","next_reset_at":1802592000},
             {"credit_total":400000000,"credit_residual":100000000,"expire_at":1801500000}]}}
        """,
      "GetStepPlanStatus": #"{"status":1,"subscription":{"name":"Flash Max"}}"#
    ])
    let usage = try await StepFunQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)

    // Bucket-weighted: (720M + 100M) / (800M + 400M) ≈ 68.3%.
    XCTAssertEqual(usage.metrics[0].id, "stepfun-credit")
    XCTAssertEqual(usage.metrics[0].remainingPercent, 68)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "380.0M credits")
    XCTAssertEqual(usage.metrics[0].totalDisplay, "1200.0M credits")
    XCTAssertEqual(usage.metrics[0].resetAt, Date(timeIntervalSince1970: 1_802_592_000))
    XCTAssertEqual(usage.metrics[1].id, "stepfun-topup")
    XCTAssertEqual(usage.metrics[1].remainingPercent, 50)
    XCTAssertEqual(
      usage.metrics.map { QuotaWindowKind.classify(metricID: $0.id, label: $0.label) },
      [.monthly, .other])
  }

  func testCreditPlanWithoutBucketsUsesSubscriptionRate() async throws {
    let http = StubHTTP(bodies: [
      "QueryStepPlanRateLimit": """
        {"status":1,"plan_family":2,
         "plan_credit_rate_limit":{"subscription_credit_left_rate":0.25,
           "subscription_credit_reset_time":"1802592000"}}
        """
    ])
    let usage = try await StepFunQuotaClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)
    XCTAssertEqual(usage.metrics.map(\.id), ["stepfun-credit"])
    XCTAssertEqual(usage.metrics[0].remainingPercent, 25)
    XCTAssertNil(usage.metrics[0].usedDisplay)
  }

  func testAPIFailureMaps() async throws {
    let http = StubHTTP(bodies: [
      "QueryStepPlanRateLimit": #"{"status":0,"code":40101,"message":"auth failed: oasis-token is embezzled"}"#
    ])
    do {
      _ = try await StepFunQuotaClient(httpClient: http).fetchUsage(configuration: configuration, now: now)
      XCTFail("expected error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
      XCTAssertFalse(error.message.contains("embezzled"))
    }
  }

  func testMissingToken() async {
    var config = configuration
    config.credentials = [:]
    do {
      _ = try await StepFunQuotaClient(httpClient: StubHTTP(bodies: [:])).fetchUsage(configuration: config, now: now)
      XCTFail("expected error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
    } catch { XCTFail("unexpected \(error)") }
  }
}

final class StepFunDiscoveryTests: XCTestCase {
  func testScansStepCodeAuthFile() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("stepfun-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appendingPathComponent(".stepcode")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try """
    {"step": {"access": "acc.jwt.here", "refresh": "ref.jwt.here", "site": "ai"},
     "other": {"token": "not-stepfun"}}
    """.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

    let result = CredentialDiscovery(homeDirectories: [home]).discover()
    let found = result.credentials.filter { $0.provider == .stepfun }
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found[0].stableID, "stepfun:stepcode:step")
    XCTAssertEqual(found[0].credentials[CredentialField.stepfunOasisToken], "acc.jwt.here...ref.jwt.here")
    XCTAssertEqual(found[0].credentials[CredentialField.stepfunSite], "ai")
  }
}
