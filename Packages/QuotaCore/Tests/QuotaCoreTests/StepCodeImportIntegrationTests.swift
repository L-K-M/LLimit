import Foundation
import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StepCodeImportIntegrationTests: XCTestCase {
  func testImportedPlanKeyCanFetchQuotaWithoutConsoleSession() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".stepcode"), withIntermediateDirectories: true)
    let auth = Data(#"{"step":{"type":"oauth","profile":"step_plan_oversea","access":"fixture-plan-key","uid":"123","refresh":"step-static-credential"}}"#.utf8)
    try auth.write(to: home.appendingPathComponent(".stepcode/auth.json"))
    let detected = try XCTUnwrap(CredentialDiscovery(homeDirectories: [home], environment: [:]).discover().credentials.first { $0.provider == .stepFun })
    XCTAssertNil(detected.credentials[CredentialField.stepFunBrowserSession])
    let config = ProviderRuntimeConfiguration(accountID: "fixture-account", provider: .stepFun,
      displayName: "StepFun", isEnabled: true, credentials: detected.credentials)
    let usage = try await StepFunQuotaClient(httpClient: PlanImportHTTP()).fetchUsage(configuration: config,
      now: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(usage.metrics.first?.remainingPercent, 75)
    XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(".stepcode/auth.json")), auth)
  }
}

private struct PlanImportHTTP: HTTPClient {
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(redirects, .refuse)
    return try await data(for: request)
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTAssertEqual(request.url?.absoluteString, "https://api.stepfun.ai/step_plan/v1/usage")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-plan-key")
    let body = #"{"schema_version":1,"observed_at_ms":1700000000000,"scope":"personal_account","account":{"id":"123"},"plan":{"state":"known","family":"token","name":null,"subscription":null},"quota":{"state":"known","allowed":true,"reason":null,"windows":[],"credit_buckets":[{"type":"subscription","total":"100","remaining":"75","used_percent":25,"resets_at_ms":null,"expires_at_ms":null}]}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
