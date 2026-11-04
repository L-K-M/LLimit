import Foundation

/// Creates disposable checkouts without writing the source repository or
/// sharing its Git object files. Trials all use the same pinned commit.
public struct BenchmarkWorkspace {
  private static let git = URL(fileURLWithPath: "/usr/bin/git")
  private static let safeArguments = [
    "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
    "-c", "protocol.allow=never", "-c", "protocol.file.allow=always",
    "-c", "core.attributesFile=/dev/null", "-c", "submodule.recurse=false"
  ]

  public static func commit(repository: URL, process: BenchmarkProcess) async throws -> String {
    let result = try await checkedGit(
      ["rev-parse", "--verify", "HEAD^{commit}"], directory: repository, process: process)
    let commit = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard validCommit(commit) else { throw BenchmarkWorkspaceError.invalidRepository }
    let submodules = try await checkedGit(
      ["ls-tree", "-r", commit], directory: repository, process: process)
    guard !submodules.split(separator: "\n").contains(where: { $0.hasPrefix("160000 ") }) else {
      throw BenchmarkWorkspaceError.submodulesUnsupported
    }
    return commit
  }

  public static func create(
    repository: URL, commit: String, destination: URL, process: BenchmarkProcess
  ) async throws {
    guard validCommit(commit), repository.isFileURL, destination.isFileURL,
          !FileManager.default.fileExists(atPath: destination.path) else {
      throw BenchmarkWorkspaceError.invalidRepository
    }
    let parent = destination.deletingLastPathComponent()
    // The caller owns this private reports directory. Resolve it once so a
    // symlink in a user-selected path cannot redirect a disposable checkout.
    guard parent.standardizedFileURL.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      _ = try await checkedGit(
        ["clone", "--no-local", "--no-hardlinks", "--no-checkout", "--no-recurse-submodules", "--", repository.path, destination.path],
        directory: parent, process: process)
      _ = try await checkedGit(
        ["checkout", "--detach", commit, "--"], directory: destination, process: process)
      // A normal clone points origin back at the source checkout. An agent
      // following repository push instructions must not write into that source.
      _ = try await checkedGit(
        ["remote", "remove", "origin"], directory: destination, process: process)
      try rejectEscapingSymlinks(in: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  public static func patch(directory: URL, baselineCommit: String? = nil, process: BenchmarkProcess) async throws -> String {
    if let baselineCommit, !validCommit(baselineCommit) { throw BenchmarkWorkspaceError.invalidRepository }
    // Intent-to-add includes untracked output in the review without running
    // clean filters or changing the agent's file bytes.
    _ = try await checkedGit(
      ["-c", "core.safecrlf=false", "add", "--intent-to-add", "--all", "--", "."],
      directory: directory, process: process)
    return try await checkedGit(
      ["diff", "--no-ext-diff", "--no-textconv", "--binary", baselineCommit ?? "HEAD", "--", "."],
      directory: directory, process: process)
  }

  private static func validCommit(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func checkedGit(
    _ arguments: [String], directory: URL, process: BenchmarkProcess
  ) async throws -> String {
    var environment = BenchmarkProcess.defaultEnvironment()
    // User/global Git filters and helpers can run arbitrary commands or change
    // checkout contents. A benchmark snapshot uses only repository file bytes.
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_LFS_SKIP_SMUDGE"] = "1"
    let result = try await process.run(
      executable: git, arguments: safeArguments + arguments, directory: directory,
      timeout: 60, environment: environment)
    guard !result.timedOut, result.status == 0,
          !result.stderr.contains("[Output truncated") else {
      throw BenchmarkWorkspaceError.gitFailed
    }
    return result.stdout
  }

  private static func rejectEscapingSymlinks(in directory: URL) throws {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    for case let item as URL in enumerator {
      if item.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
      if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root) else { throw BenchmarkWorkspaceError.unsafePath }
      }
    }
  }
}

public enum BenchmarkWorkspaceError: LocalizedError {
  case invalidRepository
  case submodulesUnsupported
  case unsafePath
  case gitFailed

  public var errorDescription: String? {
    switch self {
    case .invalidRepository: return "Choose a Git repository with a committed revision and a new trial directory."
    case .submodulesUnsupported: return "Benchmark snapshots do not support Git submodules yet."
    case .unsafePath: return "The trial directory contains a path or symbolic link outside its checkout."
    case .gitFailed: return "Could not prepare or inspect the benchmark checkout. Check Git and the selected repository."
    }
  }
}
