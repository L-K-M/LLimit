import XCTest
@testable import QuotaCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The settings file is the only credential-bearing file LLimit writes. These
/// tests pin its permission contract: created 0600 from the first byte (not
/// umask-loose then tightened), replaced atomically, and left untouched when a
/// save cannot complete.
final class SettingsStorePermissionTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("llimit-settings-permissions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeStore() -> SettingsStore {
    SettingsStore(fileURL: directory.appendingPathComponent("quota-settings.json"))
  }

  private func modeBits(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
  }

  private func tempArtifacts() -> [String] {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return contents.filter { $0.hasSuffix(".tmp") || $0.contains(".tmp") }
  }

  private var sampleSettings: AppSettings {
    AppSettings(
      accounts: [
        ProviderAccount(
          provider: .anthropic,
          displayName: "Claude",
          isEnabled: true,
          credentials: [CredentialField.anthropicAccessToken: "sk-ant-secret"]
        )
      ]
    )
  }

  // The credential payload is on disk the moment the first byte lands. A
  // umask-created 0644 temp file exposes it even though the final chmod (run
  // after the rename) would end at 0600.
  func testSaveCreatesFileWithOwnerOnlyModeUnderPermissiveUmask() throws {
    let previousMask = umask(0o022)
    defer { _ = umask(previousMask) }

    try makeStore().save(sampleSettings)

    XCTAssertEqual(try modeBits(directory.appendingPathComponent("quota-settings.json")), 0o600)
  }

  func testOverwriteKeepsOwnerOnlyModeAndRoundTrips() throws {
    let store = makeStore()
    try store.save(sampleSettings)

    var updated = sampleSettings
    updated.accounts[0].displayName = "Claude 2"
    try store.save(updated)

    XCTAssertEqual(try modeBits(directory.appendingPathComponent("quota-settings.json")), 0o600)
    XCTAssertEqual(try store.load().accounts.first?.displayName, "Claude 2")
    XCTAssertEqual(try store.load().accounts.first?.credentials[CredentialField.anthropicAccessToken], "sk-ant-secret")
    XCTAssertTrue(tempArtifacts().isEmpty, "no temp files may survive a successful save")
  }

  // A save that cannot write must fail loudly and leave the previous
  // credential file byte-for-byte intact.
  func testFailedSaveLeavesExistingFileUntouched() throws {
    let store = makeStore()
    try store.save(sampleSettings)
    let fileURL = directory.appendingPathComponent("quota-settings.json")
    let original = try Data(contentsOf: fileURL)

    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

    var disabled = sampleSettings
    disabled.accounts[0].isEnabled = false
    XCTAssertThrowsError(try store.save(disabled))

    XCTAssertEqual(try Data(contentsOf: fileURL), original)
    XCTAssertEqual(try modeBits(fileURL), 0o600)
  }

  // The credential bytes exist on disk before the rename completes, so any
  // intermediate file must already be owner-only. Polls the directory during
  // a deliberately large save; skips only when no intermediate was observed.
  func testIntermediateFileIsNeverGroupOrWorldReadable() async throws {
    let huge = AppSettings(
      accounts: (0..<2_000).map { index in
        ProviderAccount(
          provider: .openAI,
          displayName: "Account \(index)",
          isEnabled: true,
          credentials: [
            CredentialField.openAIAccessToken: String(repeating: "a", count: 1_024),
            CredentialField.openAIRefreshToken: String(repeating: "b", count: 1_024)
          ]
        )
      }
    )

    let store = makeStore()
    let sampler = ModeSampler()
    let samplerTask = Task {
      while !Task.isCancelled {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? []
        for name in names where name != "quota-settings.json" {
          // An entry that vanishes between listing and stat (already renamed
          // away) is unobservable, not evidence.
          if let mode = try? self.modeBits(self.directory.appendingPathComponent(name)) {
            await sampler.record(mode)
          }
        }
      }
    }
    defer { samplerTask.cancel() }

    try store.save(huge)

    let observed = await sampler.observed
    guard !observed.isEmpty else {
      throw XCTSkip("No intermediate file was observed during the save window")
    }
    for (mode, count) in observed {
      XCTAssertTrue(
        mode & ~0o600 == 0,
        "intermediate file observed \(count)x with mode 0o\(String(mode, radix: 8)) — group/world bits must never be set"
      )
    }
  }
}

/// Counts observed intermediate-file modes from the polling task; an actor
/// because the macOS build enforces strict concurrency on captured vars.
private actor ModeSampler {
  private(set) var observed: [Int: Int] = [:]

  func record(_ mode: Int) {
    observed[mode, default: 0] += 1
  }
}
