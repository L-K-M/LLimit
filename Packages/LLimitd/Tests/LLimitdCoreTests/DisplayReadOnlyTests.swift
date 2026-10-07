import XCTest
import QuotaCore
import LLimitdCore

final class DisplayReadOnlyTests: XCTestCase {
  func testStatusNeverLoadsSettingsOrRecoversCorruptSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = LinuxPaths(configHome: directory.appendingPathComponent("config"),
                           dataHome: directory.appendingPathComponent("data"))
    try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
    let original = Data("malformed snapshot".utf8)
    try original.write(to: paths.snapshotFileURL)
    try Data("invalid settings with fixture-private-value".utf8).write(to: paths.settingsFileURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.snapshotFileURL.path)

    var buildDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    #if os(macOS)
    buildDirectory = buildDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #endif
    let process = Process()
    process.executableURL = buildDirectory.appendingPathComponent("llimit")
    process.arguments = ["status", "--json"]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = directory.path
    environment["XDG_CONFIG_HOME"] = paths.configHome.path
    environment["XDG_DATA_HOME"] = paths.dataHome.path
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(output, StatusRenderer.waybarJSON(snapshot: nil) + "\n")
    // Decode warnings stay on stderr; stdout remains one no-data JSON object.
    XCTAssertEqual(errors, "llimit: could not read the snapshot\n")
    XCTAssertFalse(output.contains("fixture-private-value"))
    XCTAssertFalse(errors.contains("fixture-private-value"))
    XCTAssertEqual(try Data(contentsOf: paths.snapshotFileURL), original)
    let after = try FileManager.default.attributesOfItem(atPath: paths.snapshotFileURL.path)
    XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
    XCTAssertEqual(after[.posixPermissions] as? NSNumber, attributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path),
                   [paths.snapshotFileURL.lastPathComponent])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.configDirectory.path),
                   [paths.settingsFileURL.lastPathComponent])
  }
}
