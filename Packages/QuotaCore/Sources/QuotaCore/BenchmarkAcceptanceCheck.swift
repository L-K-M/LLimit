import Foundation

/// A setup check against the committed baseline, separate from candidate results.
public struct BenchmarkAcceptanceCheckResult: Sendable {
  public let baselineCommit: String
  public let exitCode: Int32
  public let timedOut: Bool
  public let output: String
  public var passed: Bool { exitCode == 0 && !timedOut }
}

public actor BenchmarkAcceptanceCheck {
  private let process = BenchmarkProcess()
  private var running = false

  public init() {}

  public func check(repository: URL, command: String, timeout: Double,
                    redactor: BenchmarkRedactor = BenchmarkRedactor(configurations: []),
                    credentialSource: @escaping @Sendable () async -> BenchmarkRedactor = { BenchmarkRedactor(configurations: []) }) async throws -> BenchmarkAcceptanceCheckResult {
    guard !running else { throw BenchmarkError.busy }
    guard repository.isFileURL, repository.path.hasPrefix("/"),
          !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !command.contains("\0"), command.utf8.count <= 16_384,
          timeout.isFinite, (1...BenchmarkPlan.maximumTimeoutSeconds).contains(timeout) else {
      throw BenchmarkValidationError.invalid("Choose a repository, a nonblank test command and a valid timeout before checking the baseline.")
    }
    running = true
    defer { running = false }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("llimit-acceptance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = repository.standardizedFileURL.resolvingSymlinksInPath()
    let commit = try await BenchmarkWorkspace.commit(repository: repository, process: process)
    let workspace = root.appendingPathComponent("baseline", isDirectory: true)
    try await BenchmarkWorkspace.create(repository: repository, commit: commit, destination: workspace, process: process)
    let result = try await process.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
      directory: workspace, timeout: timeout, environment: BenchmarkRunner.environment(executable: URL(fileURLWithPath: "/bin/sh")))
    let safe = redactor.merging(await credentialSource())
    let output = result.stdout + (result.stderr.isEmpty ? "" : "\n\nStandard error:\n" + result.stderr)
    return BenchmarkAcceptanceCheckResult(baselineCommit: commit, exitCode: result.status,
      timedOut: result.timedOut, output: safe.redact(output))
  }
}
