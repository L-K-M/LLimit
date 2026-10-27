import XCTest
@testable import QuotaCore

final class StepCodeDiscoveryTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-stepcode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: home)
  }

  private func write(_ object: [String: Any], at relativePath: String = ".stepcode/auth.json") throws {
    let url = home.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
  }

  private func entry(key: String = "step-plan-key-fixture", uid: Any? = nil) -> [String: Any] {
    var value: [String: Any] = ["type": "oauth", "profile": "step_plan_oversea", "access": key]
    if let uid { value["uid"] = uid }
    return value
  }

  private func discover(_ environment: [String: String] = [:]) -> CredentialDiscoveryResult {
    CredentialDiscovery(homeDirectories: [home], environment: environment).discover()
  }

  private func stepAccounts(_ environment: [String: String] = [:]) -> [DiscoveredCredential] {
    discover(environment).credentials.filter { $0.provider == .stepFun }
  }

  func testImportsOnlyGlobalPersonalPlanKeyAndOptionalUID() throws {
    var step = entry(key: "  step-plan-key-fixture\n", uid: "12345")
    step["refresh"] = "step-static-credential"
    step["expires"] = 9_007_199_254_740_991 as Int64
    step["login"] = ["accessToken": "passport-access-fixture", "refreshToken": "passport-refresh-fixture"]
    try write(["step": step])
    try write(["accessToken": "separate-access-fixture", "refreshToken": "separate-refresh-fixture"],
              at: ".stepcode/step-login.json")

    let result = discover()
    let account = try XCTUnwrap(result.credentials.first { $0.provider == .stepFun })
    XCTAssertEqual(account.stableID, "stepfun:step-code")
    XCTAssertEqual(account.suggestedName, "StepFun")
    XCTAssertEqual(account.sourceLabel, "Step Code (~/.stepcode/auth.json)")
    XCTAssertEqual(account.credentials, [CredentialField.stepFunPlanKey: "step-plan-key-fixture",
                                        CredentialField.stepFunUserID: "12345"])
    XCTAssertTrue(account.provider.hasRequiredCredentials(account.credentials))
    for secret in ["step-plan-key-fixture", "passport-access-fixture", "passport-refresh-fixture",
                   "separate-access-fixture", "separate-refresh-fixture"] {
      XCTAssertFalse(result.diagnostics.joined().contains(secret))
    }
  }

  func testNormalizesValidUIDAndOmitsMalformedUIDWithoutLosingPlanKey() throws {
    let cases: [(Any, String?)] = [
      ("00042", "42"), ("9223372036854775807", "9223372036854775807"),
      ("0", nil), ("-1", nil), ("9223372036854775808", nil), ("1e3", nil),
      ("user-42", nil), (42, nil), (true, nil), (NSNull(), nil)
    ]
    for (source, expected) in cases {
      try write(["step": entry(uid: source)])
      let account = try XCTUnwrap(stepAccounts().first)
      XCTAssertEqual(account.credentials[CredentialField.stepFunPlanKey], "step-plan-key-fixture")
      XCTAssertEqual(account.credentials[CredentialField.stepFunUserID], expected)
    }
    try write(["step": entry()])
    XCTAssertEqual(stepAccounts().first?.credentials, [CredentialField.stepFunPlanKey: "step-plan-key-fixture"])
  }

  func testRejectsOtherProfilesAndCredentialShapes() throws {
    var rejectedEntries: [Any] = [NSNull(), "malformed-fixture", ["access": "untyped-fixture"]]
    for profile in ["step_plan", "platform_cn", "platform_oversea", "unknown", ""] {
      var value = entry()
      value["profile"] = profile
      rejectedEntries.append(value)
    }
    for type in ["api_key", "api", "OAuth", ""] {
      var value = entry()
      value["type"] = type
      rejectedEntries.append(value)
    }
    for rejected in rejectedEntries {
      try write(["step": rejected])
      XCTAssertTrue(stepAccounts().isEmpty)
    }
    for object in [entry(), ["apiKey": "legacy-fixture"], ["stepfun": entry()], ["Step": entry()]] {
      try write(object)
      XCTAssertTrue(stepAccounts().isEmpty)
    }
  }

  func testRejectsBlankUnresolvedNonPrintableAndOversizedAccessKeys() throws {
    for key in ["", " \n", "env:STEP_API_KEY", "part\npart", "part\tpart", "part\u{7f}part", "clé",
                String(repeating: "x", count: 32_769)] {
      try write(["step": entry(key: key)])
      XCTAssertTrue(stepAccounts().isEmpty)
    }
    try write(["step": entry(key: String(repeating: "x", count: 32_768))])
    XCTAssertEqual(stepAccounts().count, 1)
  }

  func testMalformedAndNonObjectAuthFailWithoutExposingSecrets() throws {
    let url = home.appendingPathComponent(".stepcode/auth.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    for text in ["{broken", "[1,2,3]"] {
      try Data(text.utf8).write(to: url)
      XCTAssertTrue(stepAccounts().isEmpty)
    }
    try FileManager.default.removeItem(at: url)
    let result = discover(["STEP_API_KEY": "environment-key-fixture"])
    XCTAssertTrue(result.credentials.filter { $0.provider == .stepFun }.isEmpty)
    XCTAssertFalse(result.diagnostics.joined().contains("environment-key-fixture"))
  }

  func testAbsoluteAuthPathTakesPrecedenceOverOtherLocations() throws {
    try write(["step": entry(key: "default-key-fixture")])
    try write(["step": entry(key: "isolated-key-fixture")], at: "isolated/custom-auth.json")
    let accounts = stepAccounts([
      "STEPCODE_AUTH_PATH": home.appendingPathComponent("isolated/custom-auth.json").path,
      "STEP_CODING_AGENT_DIR": "unsupported-relative-path", "STEPCODE_CONFIG_DIR": "../unsupported"
    ])
    XCTAssertEqual(accounts.map(\.credentials), [[CredentialField.stepFunPlanKey: "isolated-key-fixture"]])
    XCTAssertTrue(stepAccounts(["STEPCODE_AUTH_PATH": home.appendingPathComponent("missing.json").path]).isEmpty)
  }

  func testAgentDirectoryAndHomeRelativeConfigOverrides() throws {
    try write(["step": entry(key: "default-key-fixture")])
    try write(["step": entry(key: "agent-key-fixture")], at: "isolated/auth.json")
    let agentAccounts = stepAccounts([
      "STEP_CODING_AGENT_DIR": home.appendingPathComponent("isolated/agent").path,
      "STEPCODE_CONFIG_DIR": "../unused"
    ])
    XCTAssertEqual(agentAccounts.map(\.credentials), [[CredentialField.stepFunPlanKey: "agent-key-fixture"]])

    try write(["step": entry(key: "config-key-fixture")], at: "custom-config/auth.json")
    XCTAssertEqual(stepAccounts(["STEPCODE_CONFIG_DIR": "custom-config"]).map(\.credentials),
                   [[CredentialField.stepFunPlanKey: "config-key-fixture"]])
  }

  func testUnsupportedPathOverridesNeverImportOrdinaryLogin() throws {
    try write(["step": entry(key: "default-key-fixture")])
    for environment in [
      ["STEPCODE_AUTH_PATH": "relative/auth.json"], ["STEP_CODING_AGENT_DIR": "relative/agent"],
      ["STEPCODE_CONFIG_DIR": "../outside"], ["STEPCODE_CONFIG_DIR": "nested/../outside"],
      ["STEPCODE_CONFIG_DIR": "/absolute/config"]
    ] {
      let result = discover(environment)
      XCTAssertTrue(result.credentials.filter { $0.provider == .stepFun }.isEmpty)
      XCTAssertTrue(result.diagnostics.contains { $0.hasPrefix("Step Code:") })
      XCTAssertFalse(result.diagnostics.joined().contains("default-key-fixture"))
    }
  }

  func testOnlyFixedGlobalPersonalPlanEndpointCanBeImported() throws {
    try write(["step": entry()])
    for endpoint in ["https://api.stepfun.com/step_plan", "https://elsewhere.example/step_plan",
                     "https://api.stepfun.ai/step_plan?query=1", "///https://api.stepfun.ai/step_plan"] {
      let result = discover(["STEPCODE_STEP_PLAN_API_OVERSEA_URL": endpoint])
      XCTAssertTrue(result.credentials.filter { $0.provider == .stepFun }.isEmpty)
      XCTAssertEqual(result.diagnostics.last, "Step Code: custom global Plan endpoint is not supported")
    }
    XCTAssertEqual(stepAccounts(["STEPCODE_STEP_PLAN_API_OVERSEA_URL": " https://api.stepfun.ai/step_plan/// "]).count, 1)
    XCTAssertEqual(stepAccounts([
      "STEP_API_KEY": "environment-key-fixture", "STEP_BASE_URL": "https://elsewhere.example",
      "STEPCODE_STEP_PLAN_API_URL": "https://china-override.example",
      "STEPCODE_DEVCENTER_AUTH_OVERSEA_URL": "https://auth-override.example"
    ]).count, 1)
  }

  func testMatchesOnlyActivePlanKeyWithCompatibleUID() throws {
    try write(["step": entry(uid: "42")])
    let detected = try XCTUnwrap(stepAccounts().first)
    func stored(_ key: String?, uid: String? = nil, browser: Bool = false) -> ProviderAccount {
      var credentials: [String: String] = [:]
      credentials[CredentialField.stepFunPlanKey] = key
      credentials[CredentialField.stepFunUserID] = uid
      if browser { credentials[CredentialField.stepFunBrowserSession] = "browser-session-fixture" }
      return ProviderAccount(provider: .stepFun, credentials: credentials)
    }
    XCTAssertTrue(detected.matchesStoredAccount(stored("step-plan-key-fixture", uid: "42")))
    XCTAssertTrue(detected.matchesStoredAccount(stored("step-plan-key-fixture", uid: "00042")))
    XCTAssertTrue(detected.matchesStoredAccount(stored("step-plan-key-fixture")))
    XCTAssertTrue(detected.matchesStoredAccount(stored("step-plan-key-fixture", uid: "42", browser: true)))
    XCTAssertFalse(detected.matchesStoredAccount(stored("different-key-fixture", uid: "42")))
    XCTAssertFalse(detected.matchesStoredAccount(stored("step-plan-key-fixture", uid: "43")))
    XCTAssertFalse(detected.matchesStoredAccount(stored("step-plan-key-fixture", uid: "invalid")))
    XCTAssertFalse(detected.matchesStoredAccount(stored(nil, uid: "42", browser: true)))
    XCTAssertFalse(detected.matchesStoredAccount(stored("env:STEP_API_KEY", uid: "42")))

    try write(["step": entry()])
    let withoutUID = try XCTUnwrap(stepAccounts().first)
    XCTAssertTrue(withoutUID.matchesStoredAccount(stored("step-plan-key-fixture", uid: "42")))
  }
}
