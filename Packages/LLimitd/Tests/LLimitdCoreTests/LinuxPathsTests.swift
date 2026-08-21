import XCTest
@testable import LLimitdCore

final class LinuxPathsTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/home/fixture", isDirectory: true)

  private func environment(
    xdgConfig: String? = nil,
    xdgData: String? = nil
  ) -> [String: String] {
    var environment = ["HOME": home.path]
    if let xdgConfig { environment["XDG_CONFIG_HOME"] = xdgConfig }
    if let xdgData { environment["XDG_DATA_HOME"] = xdgData }
    return environment
  }

  func testDefaultsFollowXDGSpecWhenVariablesUnset() {
    let paths = LinuxPaths(environment: environment())

    XCTAssertEqual(paths.configHome.path, "/home/fixture/.config")
    XCTAssertEqual(paths.dataHome.path, "/home/fixture/.local/share")
    XCTAssertEqual(
      paths.settingsFileURL.path,
      "/home/fixture/.config/LLimit/quota-settings.json"
    )
    XCTAssertEqual(
      paths.snapshotFileURL.path,
      "/home/fixture/.local/share/LLimit/quota-snapshot.json"
    )
    XCTAssertEqual(
      paths.historyFileURL.path,
      "/home/fixture/.local/share/LLimit/quota-history.json"
    )
  }

  func testHonorsAbsoluteXDGVariables() {
    let paths = LinuxPaths(environment: environment(
      xdgConfig: "/tmp/custom-config",
      xdgData: "/tmp/custom-data"
    ))

    XCTAssertEqual(paths.settingsFileURL.path, "/tmp/custom-config/LLimit/quota-settings.json")
    XCTAssertEqual(paths.snapshotFileURL.path, "/tmp/custom-data/LLimit/quota-snapshot.json")
    XCTAssertEqual(paths.historyFileURL.path, "/tmp/custom-data/LLimit/quota-history.json")
  }

  func testRelativeXDGValuesAreIgnoredPerSpec() {
    let paths = LinuxPaths(environment: environment(
      xdgConfig: "relative/config",
      xdgData: "relative/data"
    ))

    XCTAssertEqual(paths.configHome.path, "/home/fixture/.config")
    XCTAssertEqual(paths.dataHome.path, "/home/fixture/.local/share")
  }

  func testEmptyXDGValuesFallBackToDefaults() {
    let paths = LinuxPaths(environment: environment(xdgConfig: "", xdgData: ""))

    XCTAssertEqual(paths.configHome.path, "/home/fixture/.config")
    XCTAssertEqual(paths.dataHome.path, "/home/fixture/.local/share")
  }

  func testFileNamesMatchTheMacOSSnapshotContract() {
    let paths = LinuxPaths(environment: environment())

    XCTAssertEqual(paths.settingsFileURL.lastPathComponent, "quota-settings.json")
    XCTAssertEqual(paths.snapshotFileURL.lastPathComponent, "quota-snapshot.json")
    XCTAssertEqual(paths.historyFileURL.lastPathComponent, "quota-history.json")
    XCTAssertEqual(paths.settingsFileURL.deletingLastPathComponent().lastPathComponent, "LLimit")
    XCTAssertEqual(paths.snapshotFileURL.deletingLastPathComponent().lastPathComponent, "LLimit")
  }
}
