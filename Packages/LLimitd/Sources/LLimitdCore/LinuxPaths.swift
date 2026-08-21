import Foundation

/// Linux file locations for LLimit, replacing `Shared/SharedConstants.swift` from the
/// macOS app. There is no App Group on Linux, so the split follows the XDG Base
/// Directory specification instead:
///
///   settings -> $XDG_CONFIG_HOME/LLimit/quota-settings.json   (mode 0600, holds credentials)
///   snapshot -> $XDG_DATA_HOME/LLimit/quota-snapshot.json     (credential-free, read by bars)
///   history  -> $XDG_DATA_HOME/LLimit/quota-history.json
///
/// File names match the macOS ones so the snapshot contract stays identical.
public struct LinuxPaths: Sendable, Equatable {
  public var configHome: URL
  public var dataHome: URL

  /// Resolves against the process environment. `XDG_CONFIG_HOME` / `XDG_DATA_HOME`
  /// are honored only when set to an absolute path (the XDG spec says relative
  /// values are invalid and must be ignored); the fallbacks are `~/.config` and
  /// `~/.local/share`.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) {
    let home: URL
    if let envHome = environment["HOME"], !envHome.isEmpty {
      home = URL(fileURLWithPath: envHome, isDirectory: true)
    } else {
      home = fileManager.homeDirectoryForCurrentUser
    }

    self.init(
      configHome: LinuxPaths.xdgBaseDirectory(
        environment["XDG_CONFIG_HOME"],
        fallback: home.appendingPathComponent(".config", isDirectory: true)
      ),
      dataHome: LinuxPaths.xdgBaseDirectory(
        environment["XDG_DATA_HOME"],
        fallback: home.appendingPathComponent(".local/share", isDirectory: true)
      )
    )
  }

  public init(configHome: URL, dataHome: URL) {
    self.configHome = configHome
    self.dataHome = dataHome
  }

  public var configDirectory: URL {
    configHome.appendingPathComponent("LLimit", isDirectory: true)
  }

  public var dataDirectory: URL {
    dataHome.appendingPathComponent("LLimit", isDirectory: true)
  }

  /// The only file that may contain credentials. Written mode 0600 by SettingsStore.
  public var settingsFileURL: URL {
    configDirectory.appendingPathComponent("quota-settings.json")
  }

  public var snapshotFileURL: URL {
    dataDirectory.appendingPathComponent("quota-snapshot.json")
  }

  public var historyFileURL: URL {
    dataDirectory.appendingPathComponent("quota-history.json")
  }

  static func xdgBaseDirectory(_ value: String?, fallback: URL) -> URL {
    guard let value, !value.isEmpty, value.hasPrefix("/") else {
      return fallback
    }
    return URL(fileURLWithPath: value, isDirectory: true)
  }
}
