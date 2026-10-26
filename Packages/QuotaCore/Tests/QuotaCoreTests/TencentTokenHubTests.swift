import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TencentCloudTC3Tests: XCTestCase {
  private let secretID = "AKIDz8krbsJ5yKBZQpn74WFkmLPx3*******"
  private let secretKey = "Gu5t9xGARNpq86cd98joQYCN3*******"

  func testSHA256Vectors() {
    // FIPS 180-4 known answers.
    XCTAssertEqual(SHA256.hexDigest(Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    XCTAssertEqual(SHA256.hexDigest(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(SHA256.hexDigest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  }

  func testHMACSHA256Vectors() {
    // RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?".
    XCTAssertEqual(
      HMACSHA256.hexSign(key: [UInt8]("Jefe".utf8), message: [UInt8]("what do ya want for nothing?".utf8)),
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    // Case 6: 131-byte key — exercises the key-longer-than-blocksize path.
    let longKey = [UInt8](repeating: 0xaa, count: 131)
    XCTAssertEqual(
      HMACSHA256.hexSign(key: longKey,
        message: [UInt8]("Test Using Larger Than Block-Size Key - Hash Key First".utf8)),
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
  }

  /// Tencent's published signature example (cloud.tencent.com/document/api/1300/81014),
  /// recomputed for this client's "application/json" content type. Expected
  /// values were generated with an independent Python hmac/hashlib TC3 port.
  func testSignedRequestMatchesReferenceVector() throws {
    let signer = TencentCloudTC3Signer(
      secretID: secretID, secretKey: secretKey, service: "cvm", region: "ap-guangzhou")
    let body = Data("{\"Limit\": 1, \"Filters\": [{\"Values\": [\"\\u672a\\u547d\\u540d\"], \"Name\": \"instance-name\"}]}".utf8)
    let request = try signer.signedRequest(
      action: "DescribeInstances",
      version: "2017-03-12",
      body: body,
      endpoint: URL(string: "https://cvm.tencentcloudapi.com")!,
      timestamp: Date(timeIntervalSince1970: 1_551_113_065)
    )

    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "cvm.tencentcloudapi.com")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "DescribeInstances")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Version"), "2017-03-12")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Timestamp"), "1551113065")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Region"), "ap-guangzhou")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "TC3-HMAC-SHA256 Credential=\(secretID)/2019-02-25/cvm/tc3_request, "
        + "SignedHeaders=content-type;host, "
        + "Signature=debf58125f409c97ddcf8f3f0bd71339faf86ce3b4ed6987227ebcc233a6b003")
  }

  func testSignedRequestIncludesSessionToken() throws {
    let signer = TencentCloudTC3Signer(
      secretID: secretID, secretKey: secretKey, sessionToken: "sess-token",
      service: "tokenhub", region: "ap-singapore")
    let body = Data("{\"Limit\":100,\"Offset\":0}".utf8)
    let request = try signer.signedRequest(
      action: "DescribeTokenPlanList",
      version: "2026-03-22",
      body: body,
      endpoint: URL(string: "https://tokenhub.intl.tencentcloudapi.com")!,
      timestamp: Date(timeIntervalSince1970: 1_790_000_000)
    )

    XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Token"), "sess-token")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "TC3-HMAC-SHA256 Credential=\(secretID)/2026-09-21/tokenhub/tc3_request, "
        + "SignedHeaders=content-type;host, "
        + "Signature=e43b10aeae4923c1721bd404ebf0e7db63423c8bd967bab256da42513d2cba84")
  }

  func testRejectsEndpointWithoutHost() {
    let signer = TencentCloudTC3Signer(secretID: "id", secretKey: "key", service: "tokenhub")
    XCTAssertThrowsError(try signer.signedRequest(
      action: "DescribeTokenPlanList", version: "2026-03-22", body: Data("{}".utf8),
      endpoint: URL(fileURLWithPath: "/tmp/x"), timestamp: Date()
    )) { error in
      XCTAssertEqual((error as? ProviderClientError)?.kind, .notConfigured)
    }
  }
}

final class TencentTokenHubClientTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let secretID = "AKIDfixture1234"
  private let secretKey = "secretkeyfixture"

  private var configuration: ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(
      accountID: "th",
      provider: .tencentTokenHub,
      displayName: "TokenHub",
      isEnabled: true,
      credentials: [
        CredentialField.tokenhubSecretID: secretID,
        CredentialField.tokenhubSecretKey: secretKey
      ]
    )
  }

  private func planBody(
    teamID: String = "team-1",
    totalQuota: Double = 5000, totalUsed: Double = 1200,
    exclusiveAllocated: Double = 1000, exclusiveUsed: Double = 200,
    sharedPool: Double = 0, sharedUsed: Double = 0,
    cycleStart: Double = 1_800_000_000, cycleEnd: Double = 1_802_592_000,
    status: String = "enable", stopReason: String = "NORMAL",
    productType: String = "enterprise"
  ) -> [String: Any] {
    [
      "Response": [
        "Team": [
          "TeamId": teamID,
          "Name": "Pro plan",
          "Status": status,
          "StopReason": stopReason,
          "ProductType": productType,
          "PackageInfo": [
            "TotalQuota": totalQuota,
            "TotalUsed": totalUsed,
            "TotalCycles": 3,
            "CurrentCycle": 1,
            "CycleQuota": 2000,
            "ExclusiveAllocated": exclusiveAllocated,
            "ExclusiveUsed": exclusiveUsed,
            "SharedPool": sharedPool,
            "SharedUsed": sharedUsed,
            "StartTime": "2026-09-01 00:00:00",
            "ExpireTime": "2026-12-01 00:00:00"
          ],
          "TokenSummary": [
            "CycleStartTime": cycleStart,
            "CycleEndTime": cycleEnd,
            "BillingItems": [
              ["BillingItem": "input", "TotalQty": 150],
              ["BillingItem": "output", "TotalQty": 50]
            ]
          ]
        ],
        "RequestId": "req-1"
      ]
    ]
  }

  private actor StubHTTP: HTTPClient {
    let bodies: [String: String]
    let statusCode: Int
    var requests: [URLRequest] = []

    init(bodies: [String: String] = [:], statusCode: Int = 200) {
      self.bodies = bodies
      self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      requests.append(request)
      let action = request.value(forHTTPHeaderField: "X-TC-Action") ?? ""
      let body = Data((bodies[action] ?? "{\"Response\":{\"RequestId\":\"r\"}}").utf8)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
      )!
      return (body, response)
    }
  }

  private func makeHTTP(
    list: [[String: Any]] = [["TeamId": "team-1"]],
    plan: [String: Any]
  ) throws -> StubHTTP {
    StubHTTP(bodies: [
      "DescribeTokenPlanList": String(
        decoding: try JSONSerialization.data(withJSONObject: [
          "Response": ["TokenPlanSet": list, "TotalCount": list.count, "RequestId": "r1"]
        ]), as: UTF8.self),
      "DescribeTokenPlan": String(
        decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
    ])
  }

  func testFetchesPlanAndRendersCycleMetrics() async throws {
    let http = try makeHTTP(plan: planBody())
    let usage = try await TencentTokenHubClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)

    XCTAssertEqual(usage.provider, .tencentTokenHub)
    XCTAssertEqual(usage.accountID, "th")
    XCTAssertNil(usage.warning)
    XCTAssertEqual(usage.metrics.map(\.id), ["team-1-cycle", "team-1-total"])
    XCTAssertEqual(usage.metrics[0].remainingPercent, 80)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "200 credits")
    XCTAssertEqual(usage.metrics[0].totalDisplay, "1000 credits")
    XCTAssertEqual(usage.metrics[0].resetAt, Date(timeIntervalSince1970: 1_802_592_000))
    XCTAssertEqual(usage.metrics[0].windowSeconds, 2_592_000)
    XCTAssertEqual(usage.metrics[1].remainingPercent, 76)
    XCTAssertEqual(usage.metrics[1].usedDisplay, "1200 credits")

    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-TC-Action"), "DescribeTokenPlanList")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-TC-Action"), "DescribeTokenPlan")
    XCTAssertEqual(String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self), "{\"TeamId\":\"team-1\"}")
    let auth = try XCTUnwrap(requests[0].value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(auth.hasPrefix("TC3-HMAC-SHA256 Credential=\(secretID)/"))
    XCTAssertTrue(auth.contains("tokenhub/tc3_request"))
    XCTAssertFalse(auth.contains(secretKey))
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(usage), as: UTF8.self).contains(secretKey))
  }

  func testSharedPoolAndStoppedPlan() async throws {
    let http = try makeHTTP(plan: planBody(
      sharedPool: 400, sharedUsed: 100, status: "disable", stopReason: "ARREARS"))
    let usage = try await TencentTokenHubClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)

    XCTAssertEqual(usage.warning, "Token Plan is stopped (ARREARS).")
    XCTAssertEqual(usage.metrics.map(\.id), ["team-1-cycle", "team-1-shared", "team-1-total"])
    XCTAssertEqual(usage.metrics[1].remainingPercent, 75)
    XCTAssertEqual(usage.metrics[1].label, "Pro plan shared pool")
  }

  func testNonEnterprisePlansUseTokenUnits() async throws {
    let http = try makeHTTP(plan: planBody(productType: "personal"))
    let usage = try await TencentTokenHubClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)
    XCTAssertEqual(usage.metrics[0].usedDisplay, "200 tokens")
    XCTAssertEqual(usage.metrics[0].totalDisplay, "1000 tokens")
  }

  func testCycleFallsBackToCycleQuotaWithoutExclusivePool() async throws {
    let http = try makeHTTP(plan: planBody(exclusiveAllocated: 0, exclusiveUsed: 0))
    let usage = try await TencentTokenHubClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)
    XCTAssertEqual(usage.metrics.map(\.id), ["team-1-cycle", "team-1-total"])
    XCTAssertNil(usage.metrics[0].remainingPercent)
    XCTAssertEqual(usage.metrics[0].totalDisplay, "2000 credits")
  }

  func testEmptyPlanListWarns() async throws {
    let http = try makeHTTP(list: [], plan: [:])
    let usage = try await TencentTokenHubClient(httpClient: http)
      .fetchUsage(configuration: configuration, now: now)
    XCTAssertTrue(usage.metrics.isEmpty)
    XCTAssertEqual(usage.warning, "No Token Plan packages found on this Tencent Cloud account.")
  }

  func testAPIErrorMapsToAuth() async throws {
    let http = StubHTTP(bodies: [
      "DescribeTokenPlanList":
        "{\"Response\":{\"Error\":{\"Code\":\"AuthFailure.SignatureFailure\",\"Message\":\"bad sig\"},\"RequestId\":\"r\"}}"
    ])
    do {
      _ = try await TencentTokenHubClient(httpClient: http).fetchUsage(configuration: configuration, now: now)
      XCTFail("expected error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
      XCTAssertEqual(error.message, "Tencent TokenHub returned AuthFailure.SignatureFailure")
    }
  }

  func testMissingCredentials() async {
    var config = configuration
    config.credentials = [:]
    do {
      _ = try await TencentTokenHubClient(httpClient: StubHTTP()).fetchUsage(configuration: config, now: now)
      XCTFail("expected error")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .notConfigured)
      XCTAssertTrue(error.message.contains("SecretId"))
    } catch { XCTFail("unexpected \(error)") }
  }
}

final class TencentTokenHubDiscoveryTests: XCTestCase {
  func testScansThcliCredentialFiles() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("thcli-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appendingPathComponent(".thcli")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    try """
    {"secretId":"AKIDintl","secretKey":"key1","type":"key"}
    """.write(to: dir.appendingPathComponent("default.intl.credential"), atomically: true, encoding: .utf8)
    try """
    {"secretId":"AKIDcn","secretKey":"key2","token":"sess","type":"token","expiresAt":0}
    """.write(to: dir.appendingPathComponent("work.cn.credential"), atomically: true, encoding: .utf8)
    try "noise".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    let result = CredentialDiscovery(homeDirectories: [home]).discover()
    let tencent = result.credentials.filter { $0.provider == .tencentTokenHub }
    XCTAssertEqual(tencent.count, 2)

    let intl = try XCTUnwrap(tencent.first { $0.stableID == "tencent-tokenhub:thcli:intl:default" })
    XCTAssertEqual(intl.credentials[CredentialField.tokenhubSecretID], "AKIDintl")
    XCTAssertEqual(intl.credentials[CredentialField.tokenhubSecretKey], "key1")
    XCTAssertNil(intl.credentials[CredentialField.tokenhubEndpoint])

    let cn = try XCTUnwrap(tencent.first { $0.stableID == "tencent-tokenhub:thcli:cn:work" })
    XCTAssertEqual(cn.credentials[CredentialField.tokenhubSessionToken], "sess")
    XCTAssertEqual(cn.credentials[CredentialField.tokenhubEndpoint], "https://tokenhub.tencentcloudapi.com")
    XCTAssertEqual(cn.credentials[CredentialField.tokenhubRegion], "ap-guangzhou")
    XCTAssertEqual(cn.suggestedName, "Tencent TokenHub (work)")
  }
}
