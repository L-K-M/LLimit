import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkHarnessTests: XCTestCase {
  func testPiUpdatedCatalogSupportsOpenRouterTildeAliases() throws {
    let response = #"{"id":"llimit-models","type":"response","command":"get_available_models","success":true,"data":{"models":[{"provider":"openai-codex","id":"regular-model","name":"Regular model"},{"provider":"openrouter","id":"~anthropic/claude-sonnet-latest","name":"Sonnet alias"}]}}"#
    let models = try BenchmarkHarnessDiscovery.decodeModels(response, harness: .pi)
    XCTAssertEqual(models.count, 2)
    let alias = try XCTUnwrap(models.first { $0.provider == "openrouter" })
    XCTAssertEqual(alias.modelID, "~anthropic/claude-sonnet-latest")
    XCTAssertTrue(alias.command(executable: "/bin/pi", judge: false).arguments.contains("~anthropic/claude-sonnet-latest"))
    XCTAssertEqual(try BenchmarkHarnessDiscovery.decodeModels("openrouter/~anthropic/claude-sonnet-latest\n", harness: .opencode).first?.modelID,
                   "~anthropic/claude-sonnet-latest")
  }

  func testPiCatalogKeepsOnlyPublicMetadataAndStableSortedIdentifiers() throws {
    let response = #"{"id":"llimit-models","type":"response","command":"get_available_models","success":true,"data":{"models":[{"provider":"z-provider","id":"model/with/slashes","name":"Z model","headers":{"Authorization":"private-token"},"baseUrl":"https://private-endpoint.invalid","cost":{"input":1}},{"provider":"a-provider","id":"model-b","name":"B model"},{"provider":"a-provider","id":"model-b","name":"Duplicate"}]}}"#
    let models = try BenchmarkHarnessDiscovery.decodeModels(response, harness: .pi)
    XCTAssertEqual(models.map(\.provider), ["a-provider", "z-provider"])
    XCTAssertEqual(models[1].modelID, "model/with/slashes")
    let encoded = String(decoding: try JSONEncoder().encode(models), as: UTF8.self)
    XCTAssertFalse(encoded.contains("private-token"))
    XCTAssertFalse(encoded.contains("private-endpoint"))
    XCTAssertFalse(encoded.contains("headers"))
    XCTAssertFalse(encoded.contains("cost"))
  }

  func testPiCatalogRequiresMatchingSuccessfulResponse() {
    for output in ["", "not-json", #"{"type":"response","command":"get_available_models","success":true,"data":{"models":[]}}"#,
                   #"{"id":"llimit-models","type":"response","command":"get_available_models","success":false,"error":"credential-must-not-leak"}"#] {
      XCTAssertThrowsError(try BenchmarkHarnessDiscovery.decodeModels(output, harness: .pi)) { error in
        XCTAssertFalse(error.localizedDescription.contains("credential-must-not-leak"))
      }
    }
    let empty = #"{"id":"llimit-models","type":"response","command":"get_available_models","success":true,"data":{"models":[]}}"#
    XCTAssertEqual(try BenchmarkHarnessDiscovery.decodeModels(empty, harness: .pi), [])
  }

  func testOpenCodeCatalogSplitsOnlyFirstSlashAndRejectsDiagnostics() throws {
    let models = try BenchmarkHarnessDiscovery.decodeModels("openrouter/anthropic/model:free\nlocal/model-a\nlocal/model-a\n", harness: .opencode, plugins: .configured)
    XCTAssertEqual(models.count, 2)
    XCTAssertEqual(models[1].provider, "openrouter")
    XCTAssertEqual(models[1].modelID, "anthropic/model:free")
    XCTAssertTrue(models.allSatisfy { $0.pluginPolicy == .configured })
    for malformed in ["INFO loading /private/path", "provider/", "/model", "-flag/model", "provider/model\tcredential", "{\"secret\":\"private/value\"}"] {
      XCTAssertThrowsError(try BenchmarkHarnessDiscovery.decodeModels(malformed, harness: .opencode))
    }
  }

  func testSelectedModelProducesFreshStdinCommandsAndConsistentPluginPolicy() {
    let pi = BenchmarkHarnessModel(harness: .pi, provider: "provider", modelID: "model", displayName: "Model")
    let candidate = pi.command(executable: "/bin/pi", judge: false)
    XCTAssertEqual(candidate.outputFormat, .piJSON)
    XCTAssertTrue(candidate.arguments.contains("--no-session"))
    XCTAssertTrue(candidate.arguments.contains("--no-extensions"))
    XCTAssertFalse(candidate.arguments.contains("{prompt}"))
    let piJudge = pi.command(executable: "/bin/pi", judge: true)
    XCTAssertFalse(piJudge.arguments.contains("--no-tools"))
    XCTAssertTrue(piJudge.arguments.contains("read,grep,find,ls"))
    XCTAssertTrue(piJudge.arguments.contains("--no-mcp"))
    let openCode = BenchmarkHarnessModel(harness: .opencode, provider: "provider", modelID: "nested/model", displayName: "Model", pluginPolicy: .configured)
    let command = openCode.command(executable: "/bin/opencode", judge: false)
    XCTAssertTrue(command.arguments.contains("provider/nested/model"))
    XCTAssertFalse(command.arguments.contains("--pure"))
    XCTAssertFalse(command.arguments.contains("--continue"))
    XCTAssertFalse(command.arguments.contains("--session"))
  }

  func testOpenCodeJudgeAllowsInspectionWithoutInheritingProviderSecrets() throws {
    let model = BenchmarkHarnessModel(harness: .opencode, provider: "provider", modelID: "model", displayName: "Model")
    let command = model.command(executable: "/bin/opencode", judge: true)
    let environment = BenchmarkHarness.environment(for: command, parent: ["HOME": "/home/user", "OPENAI_API_KEY": "private-key", "CODEX_HOME": "/managed"])
    XCTAssertNil(environment["OPENAI_API_KEY"])
    XCTAssertNil(environment["CODEX_HOME"])
    XCTAssertEqual(environment["OPENCODE_DISABLE_MODELS_FETCH"], "1")
    let config = try XCTUnwrap(environment["OPENCODE_CONFIG_CONTENT"])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
    let agents = try XCTUnwrap(object["agent"] as? [String: Any])
    let index = try XCTUnwrap(command.arguments.firstIndex(of: "--agent"))
    let name = command.arguments[index + 1]
    XCTAssertTrue(name.hasPrefix("llimit-benchmark-inspector-"))
    let judge = try XCTUnwrap(agents[name] as? [String: Any])
    XCTAssertEqual((judge["permission"] as? [String: String])?["*"], "deny")
    XCTAssertEqual((judge["permission"] as? [String: String])?["read"], "allow")
    XCTAssertEqual((judge["permission"] as? [String: String])?["external_directory"], "deny")
    let candidate = model.command(executable: "/bin/opencode", judge: false)
    XCTAssertNil(BenchmarkHarness.environment(for: candidate)["OPENCODE_CONFIG_CONTENT"])
    XCTAssertNotEqual(command.arguments, model.command(executable: "/bin/opencode", judge: true).arguments)
  }

  func testDiscoveryUsesOnlyMetadataRequestAndCleansPrivateWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("pi-fixture")
    let directoryRecord = root.appendingPathComponent("directory")
    let script = """
    #!/bin/sh
    input=$(cat)
    test "$input" = '{"id":"llimit-models","type":"get_available_models"}' || exit 4
    printf '%s' "$PWD" > '\(directoryRecord.path)'
    printf '%s\\n' '{"id":"llimit-models","type":"response","command":"get_available_models","success":true,"data":{"models":[{"provider":"fixture","id":"model","name":"Fixture model"}]}}'
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let models = try await BenchmarkHarnessDiscovery().models(for: .pi, executable: executable, repository: nil)
    XCTAssertEqual(models.map(\.provider), ["fixture"])
    let directory = try String(contentsOf: directoryRecord)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    XCTAssertTrue(directory.contains("llimit-models-"))
  }
}
