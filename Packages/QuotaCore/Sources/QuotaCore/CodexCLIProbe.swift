import Foundation

/// Older Codex releases can treat an unknown subcommand as an agent prompt.
/// Probe only --version, without any real home/config or authentication context.
enum CodexCLIProbe {
  /// Compared by SemVer precedence, so a prerelease of a later version passes
  /// and a prerelease of this version does not.
  static let minimumVersion = CodexCLIVersion(major: 0, minor: 144, patch: 4)
  static let outputLimit = ManagedCLIVersionProbe.outputLimit

  /// Returns the first candidate that reports a supported version. Otherwise
  /// throws the first candidate's problem: the preferred install is the one to
  /// repair, and its path tells the user which install LLimit tried.
  static func firstSupported(_ candidates: [URL], environment: [String: String], timeout: TimeInterval = 2,
                             budget: TimeInterval = ManagedCLIVersionProbe.maximumTimeout) async throws -> URL {
    guard budget.isFinite, budget > 0, budget <= ManagedCLIVersionProbe.maximumTimeout else {
      throw CodexConnectionError.incompatibleCLI
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("llimit-codex-version-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    var firstProblem: CodexConnectionError?
    var seen = Set<String>()
    let deadline = Date().addingTimeInterval(budget)
    for candidate in candidates where seen.insert(candidate.path).inserted && FileManager.default.isExecutableFile(atPath: candidate.path) {
      guard !Task.isCancelled else { throw CodexConnectionError.cancelled }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      let probeEnvironment = Self.environment(for: candidate, parent: environment, home: temporary)
      guard let problem = await problem(with: candidate, environment: probeEnvironment, directory: temporary,
                                       timeout: min(timeout, remaining)) else {
        return candidate
      }
      firstProblem = firstProblem ?? problem
    }
    throw firstProblem ?? CodexConnectionError.cliNotFound
  }

  /// The probe sees no real home, Codex configuration or credential. Volta's
  /// shims still need the user's Volta directory, which defaults under HOME.
  static func environment(for candidate: URL, parent: [String: String], home: URL) -> [String: String] {
    ManagedCLIVersionProbe.environment(for: .codex, executable: candidate, parent: parent, home: home)
  }

  /// Nil when the candidate is a supported Codex CLI; otherwise why it is not.
  private static func problem(with candidate: URL, environment: [String: String], directory: URL,
                              timeout: TimeInterval) async -> CodexConnectionError? {
    let output: String
    switch await ManagedCLIVersionProbe.output(candidate, environment: environment, directory: directory, timeout: timeout) {
    case .success(let value): output = value
    case .failure(let failure): return .cliFailed(path: candidate.path, failure)
    }
    guard let version = CodexCLIVersion(versionOutput: output) else {
      return .cliFailed(path: candidate.path, .unrecognizedVersion)
    }
    guard version < minimumVersion else { return nil }
    return .cliTooOld(path: candidate.path, version: version.description)
  }

}

/// A `codex-cli X.Y.Z[-prerelease][+build]` version, ordered by SemVer
/// precedence: a prerelease precedes its release, and build metadata is ignored.
struct CodexCLIVersion: Comparable, CustomStringConvertible, Sendable {
  let major: Int
  let minor: Int
  let patch: Int
  /// Empty for a release.
  let prerelease: [String]

  init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease
  }

  /// Accepts only the single line `codex --version` prints.
  init?(versionOutput: String) {
    let parts = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "codex-cli" else { return nil }
    var text = parts[1]
    if let plus = text.firstIndex(of: "+") {
      guard Self.identifiers(text[text.index(after: plus)...]) != nil else { return nil }
      text = text[..<plus]
    }
    var prerelease: [String] = []
    if let dash = text.firstIndex(of: "-") {
      guard let identifiers = Self.identifiers(text[text.index(after: dash)...]) else { return nil }
      prerelease = identifiers
      text = text[..<dash]
    }
    let components = text.split(separator: ".", omittingEmptySubsequences: false)
    let core = components.compactMap { value -> Int? in
      guard Self.isNumeric(value) else { return nil }
      return Int(value)
    }
    guard components.count == 3, core.count == 3 else { return nil }
    self.init(major: core[0], minor: core[1], patch: core[2], prerelease: prerelease)
  }

  var description: String {
    let release = "\(major).\(minor).\(patch)"
    return prerelease.isEmpty ? release : release + "-" + prerelease.joined(separator: ".")
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
      return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    // A release has higher precedence than any of its prereleases.
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
    for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
      return identifierPrecedes(left, right)
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  /// Numeric identifiers compare numerically and precede alphanumeric ones,
  /// which compare in ASCII order.
  private static func identifierPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    switch (isNumeric(Substring(lhs)), isNumeric(Substring(rhs))) {
    case (true, true): return (lhs.count, lhs) < (rhs.count, rhs)
    case (true, false): return true
    case (false, true): return false
    case (false, false): return Array(lhs.utf8).lexicographicallyPrecedes(rhs.utf8)
    }
  }

  /// Dot-separated, non-empty `[0-9A-Za-z-]` identifiers, or nil.
  private static func identifiers(_ text: Substring) -> [String]? {
    let identifiers = text.split(separator: ".", omittingEmptySubsequences: false)
    let valid = identifiers.allSatisfy { identifier in
      !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    return valid ? identifiers.map(String.init) : nil
  }

  private static func isNumeric(_ value: Substring) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
