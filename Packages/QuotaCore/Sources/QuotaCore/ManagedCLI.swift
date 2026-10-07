import Foundation

/// An official CLI that LLimit launches for managed accounts. It owns the rules
/// for finding the installed executable and for the launch environment shared
/// by every child: login, renewal, version probe and app-server.
public enum ManagedCLI: Sendable {
  case claude, codex

  /// Parent settings that both CLIs need on top of their own allowlists. Claude
  /// Code reads the proxy variables and NODE_EXTRA_CA_CERTS; Codex reads the
  /// proxy variables, including ALL_PROXY, and SSL_CERT_FILE. Volta's shims
  /// find a relocated toolchain through VOLTA_HOME. None of them selects a
  /// provider account, endpoint or configuration directory.
  public static let sharedEnvironmentKeys: Set<String> = [
    "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
    "ALL_PROXY", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "VOLTA_HOME"
  ]

  /// The minimal PATH of a Finder or login-item launch, kept as the last resort.
  private static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
  /// Bounds a cyclic nvm alias chain.
  private static let maximumAliasHops = 8

  private var executableName: String {
    switch self {
    case .claude: return "claude"
    case .codex: return "codex"
    }
  }

  /// Possible executables in search order: the known install locations, then
  /// the parent PATH, as before, then version-manager locations that a GUI
  /// launch's PATH lacks. The caller checks which candidates exist.
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
    directories += Self.pathEntries(environment["PATH"])
    directories += Self.versionManagerDirectories(home: home, environment: environment)
    return Self.unique(directories).map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executableName) }
  }

  /// The child's PATH. npm installs a CLI as a `#!/usr/bin/env node` script, and
  /// a GUI launch's PATH has no Node.js. Homebrew, nvm and fnm keep node beside
  /// the executable; a symlinked package can also find it beside its target.
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

  /// Volta's shims locate their toolchain from VOLTA_HOME, or HOME/.volta when
  /// it is unset. A probe that runs with a private HOME must name it explicitly.
  static func voltaHome(environment: [String: String]) -> String? {
    absolute(environment["VOLTA_HOME"]) ?? absolute(environment["HOME"]).map { $0 + "/.volta" }
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
    return directories + nvmDirectories(home: home, environment: environment)
  }

  /// nvm installs each Node version, with the CLIs installed into it, under
  /// versions/node/vX.Y.Z/bin. The version a new shell selects comes first,
  /// then the others newest first.
  private static func nvmDirectories(home: String?, environment: [String: String]) -> [String] {
    guard let root = absolute(environment["NVM_DIR"]) ?? home.map({ $0 + "/.nvm" }) else { return [] }
    let versionsDirectory = root + "/versions/node"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory)) ?? []
    return orderedNodeVersions(names, defaultAlias: nvmDefaultAlias(root: root)).map { versionsDirectory + "/" + $0 + "/bin" }
  }

  /// Orders installed `vX.Y.Z` names newest first, then moves the newest one
  /// matching the default alias (`22`, `22.11` or `v22.11.0`) to the front.
  /// Other names are not Node installs and are dropped.
  static func orderedNodeVersions(_ names: [String], defaultAlias: String?) -> [String] {
    let installed = names.compactMap { name in nodeVersion(name).map { (name: name, version: $0) } }
      .sorted { $1.version.lexicographicallyPrecedes($0.version) }
    let selector = defaultAlias.flatMap { alias -> [Int]? in
      let parts = alias.drop { $0 == "v" }.split(separator: ".", omittingEmptySubsequences: false)
      let numbers = parts.compactMap { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
      return (1...3).contains(parts.count) && numbers.count == parts.count ? numbers : nil
    }
    guard let selector, let preferred = installed.firstIndex(where: { $0.version.starts(with: selector) }) else {
      return installed.map(\.name)
    }
    var ordered = installed.map(\.name)
    ordered.insert(ordered.remove(at: preferred), at: 0)
    return ordered
  }

  /// Follows nvm's alias files from `alias/default`, for example through
  /// `lts/*` and `lts/jod` to a version. Nil when no default is set.
  private static func nvmDefaultAlias(root: String) -> String? {
    let aliases = URL(fileURLWithPath: root + "/alias", isDirectory: true)
    var value = "default"
    for _ in 0..<maximumAliasHops {
      // Alias names are relative files inside alias/; never leave that directory.
      guard !value.isEmpty, !value.hasPrefix("/"), !value.split(separator: "/").contains(".."),
            let next = try? String(contentsOf: aliases.appendingPathComponent(value), encoding: .utf8) else { break }
      value = next.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value == "default" ? nil : value
  }

  private static func nodeVersion(_ name: String) -> [Int]? {
    guard name.hasPrefix("v") else { return nil }
    let parts = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
    return parts.count == 3 && numbers.count == 3 ? numbers : nil
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
