import XCTest
@testable import QuotaCore

final class JunieDiscoveryTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-junie-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: home)
  }

  private func write(secret: Any, entryKey: String = "jb-account-stored", directory: String = ".junie") throws {
    let url = home.appendingPathComponent(directory).appendingPathComponent("secure_credentials.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: ["secrets": [["key": entryKey, "secret": secret]]])
    try data.write(to: url)
  }

  private func discover(environment: [String: String] = [:]) -> CredentialDiscoveryResult {
    CredentialDiscovery(homeDirectories: [home], environment: environment).discover()
  }

  func testImportsOnlyPermanentKeyFromFallbackCredentialFile() throws {
    try write(secret: #"{"simpleToken":"perm-junie-fixture","jbAccount":{"refreshToken":"refresh-secret"}}"#)
    let result = discover()
    let account = try XCTUnwrap(result.credentials.first { $0.provider == .junie })
    XCTAssertEqual(account.stableID, "junie:cli")
    XCTAssertEqual(account.credentials, [CredentialField.junieAPIKey: "perm-junie-fixture"])
    XCTAssertTrue(account.provider.hasRequiredCredentials(account.credentials))
    XCTAssertFalse(result.diagnostics.joined().contains("perm-junie-fixture"))
    XCTAssertFalse(result.diagnostics.joined().contains("refresh-secret"))
  }

  func testHonorsAbsoluteJunieHomeAndIgnoresDefaultWhenSet() throws {
    try write(secret: #"{"simpleToken":"default-fixture"}"#)
    try write(secret: #"{"simpleToken":"custom-fixture"}"#, directory: "custom-junie")
    let result = discover(environment: ["JUNIE_HOME": home.appendingPathComponent("custom-junie").path])
    XCTAssertEqual(result.credentials.filter { $0.provider == .junie }.map(\.credentials),
                   [[CredentialField.junieAPIKey: "custom-fixture"]])
    XCTAssertFalse(result.diagnostics.joined().contains("custom-fixture"))
  }

  func testEnvironmentKeyAndFileKeyAreDeduplicated() throws {
    try write(secret: #"{"simpleToken":"perm-junie-fixture"}"#)
    let result = discover(environment: ["JUNIE_API_KEY": "  perm-junie-fixture\n"])
    let junie = result.credentials.filter { $0.provider == .junie }
    XCTAssertEqual(junie.count, 1)
    XCTAssertEqual(junie.first?.credentials, [CredentialField.junieAPIKey: "perm-junie-fixture"])
    XCTAssertFalse(result.diagnostics.joined().contains("perm-junie-fixture"))
  }

  func testDifferentEnvironmentAndFileKeysRemainSeparate() throws {
    try write(secret: #"{"simpleToken":"file-fixture"}"#)
    let result = discover(environment: ["JUNIE_API_KEY": "env-fixture"])
    let junie = result.credentials.filter { $0.provider == .junie }
    XCTAssertEqual(junie.count, 2)
    XCTAssertEqual(Set(junie.map(\.stableID)), ["junie:environment", "junie:cli"])
  }

  func testDoesNotImportRefreshGrantsBYOKOrMalformedEntries() throws {
    for secret: Any in [
      #"{"jbAccount":{"accessToken":"access-secret","refreshToken":"refresh-secret"}}"#,
      #"{"enterpriseAccount":{"token":"enterprise-secret"}}"#,
      #"{"jcpAccount":{"token":"jcp-secret"}}"#,
      #"{"apiKey":"byok-secret"}"#, #"{"simpleToken":"  "}"#,
      #"{"simpleToken":42}"#, "broken-secret", ["simpleToken": "unnested-secret"]
    ] {
      try write(secret: secret)
      let result = discover()
      XCTAssertFalse(result.credentials.contains { $0.provider == .junie })
      XCTAssertFalse(result.diagnostics.joined().contains("secret"))
    }
    try write(secret: #"{"simpleToken":"byok-secret"}"#, entryKey: "anthropic-api-key")
    XCTAssertFalse(discover().credentials.contains { $0.provider == .junie })
  }
}
