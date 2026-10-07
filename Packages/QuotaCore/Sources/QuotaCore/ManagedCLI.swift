import Foundation

/// An official CLI that LLimit launches for managed accounts. It owns the rules
/// for finding the installed executable and for the launch environment shared
/// by every child: login, renewal, version probe and app-server.
public enum ManagedCLI: Sendable {
  case claude, codex

  /// Proxy and certificate settings that both CLIs need on managed networks.
  /// Claude Code reads the proxy variables and NODE_EXTRA_CA_CERTS; Codex reads
  /// the proxy variables, including ALL_PROXY, and SSL_CERT_FILE. None of them
  /// selects a provider account, endpoint or configuration directory.
  public static let networkEnvironmentKeys: Set<String> = [
    "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
    "ALL_PROXY", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"
  ]

  /// The minimal PATH of a Finder or login-item launch, kept as the last resort.
  private static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

  private var executableName: String {
    switch self {
    case .claude: return "claude"
    case .codex: return "codex"
    }
  }

  /// Possible executables in search order: the known install locations first,
  /// then version-manager locations, then the parent PATH. The caller checks
  /// which candidates exist; a GUI launch has none of the shell's PATH setup.
  public func candidates(environment: [String: String]) -> [URL] {
    let home = Self.absolute(environment["HOME"])
    var directories: [String]
    switch self {
    case .claude:
      // The native installer's location wins over package-manager copies.
      directories = [home.map { $0 + "/.local/bin" }, "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
    case .codex:
      // Homebrew takes priority over old npm shims earlier on PATH.
      directories = ["/opt/homebrew/bin", "/usr/local/bin", home.map { $0 + "/.local/bin" }].compactMap { $0 }
    }
    directories += Self.versionManagerDirectories(home: home, environment: environment)
    directories += Self.pathEntries(environment["PATH"])
    return Self.unique(directories).map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executableName) }
  }

  /// The child's PATH. An npm, nvm, fnm or Volta install is a script starting
  /// with `#!/usr/bin/env node`, so its interpreter must be found beside the
  /// executable or beside its symlink target rather than on the parent's PATH.
  public static func searchPath(for executable: URL, environment: [String: String]) -> String {
    let launched = executable.standardizedFileURL
    var directories = [
      launched.deletingLastPathComponent().path,
      launched.resolvingSymlinksInPath().deletingLastPathComponent().path,
      "/opt/homebrew/bin", "/usr/local/bin"
    ]
    if let home = absolute(environment["HOME"]) { directories.append(home + "/.local/bin") }
    directories += pathEntries(environment["PATH"])
    directories += systemDirectories
    return unique(directories).joined(separator: ":")
  }

  /// Volta's shims locate their toolchain from HOME. A probe that runs with a
  /// private HOME must point them back at the user's Volta directory.
  static func voltaHome(environment: [String: String]) -> String? {
    absolute(environment["HOME"]).map { $0 + "/.volta" }
  }

  private static func versionManagerDirectories(home: String?, environment: [String: String]) -> [String] {
    var directories: [String] = []
    if let volta = voltaHome(environment: environment) { directories.append(volta + "/bin") }
    // npm's documented prefix for global installs without root.
    if let home { directories.append(home + "/.npm-global/bin") }

    // fnm links its default Node version, and the packages installed into it,
    // under aliases/default in the first base directory that exists.
    var fnmRoots = [absolute(environment["FNM_DIR"]), absolute(environment["XDG_DATA_HOME"]).map { $0 + "/fnm" }]
    if let home {
      fnmRoots += [home + "/.local/share/fnm", home + "/.fnm", home + "/Library/Application Support/fnm"]
    }
    directories += fnmRoots.compactMap { $0.map { $0 + "/aliases/default/bin" } }
    return directories
  }

  /// Relative entries would resolve against the child's working directory.
  private static func pathEntries(_ path: String?) -> [String] {
    (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
  }

  private static func absolute(_ path: String?) -> String? {
    guard let path, path.hasPrefix("/") else { return nil }
    return path
  }

  /// A directory containing ":" cannot be represented in PATH.
  private static func unique(_ directories: [String]) -> [String] {
    var seen = Set<String>()
    return directories.filter { !$0.contains(":") && seen.insert($0).inserted }
  }
}

/// Identifies an executable's installed file by its resolved path, size and
/// modification time, so a verified CLI is re-checked only after it changes.
public struct ManagedCLIFingerprint: Equatable, Sendable {
  public let path: String
  public let size: UInt64
  public let modified: Date

  /// Nil when the executable or its symlink target is missing or not a file.
  public init?(executable: URL) {
    let resolved = executable.resolvingSymlinksInPath().path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = (attributes[.size] as? NSNumber)?.uint64Value,
          let modified = attributes[.modificationDate] as? Date else { return nil }
    path = resolved
    self.size = size
    self.modified = modified
  }
}
