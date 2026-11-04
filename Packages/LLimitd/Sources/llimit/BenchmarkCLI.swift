import Foundation
import QuotaCore
import LLimitdCore

func runBench(_ arguments: [String]) async {
  let directory = LinuxPaths().dataDirectory.appendingPathComponent("Benchmarks", isDirectory: true)
  guard let command = arguments.first else { benchmarkUsage(); return }
  switch command {
  case "template":
    guard arguments.count == 1 else { fail("bench template takes no arguments") }
    benchmarkPrintJSON(benchmarkTemplate())
  case "run":
    guard arguments.count == 3, arguments[2] == "--exclusive-accounts" else {
      fail("use bench run <plan.json> --exclusive-accounts; this confirms each CLI uses its selected quota account and no other work uses that account during measurement")
    }
    let plan: BenchmarkPlan
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
      guard data.count <= 2 * 1_024 * 1_024 else { fail("benchmark plans must be no larger than 2 MiB") }
      plan = try JSONDecoder().decode(BenchmarkPlan.self, from: data).validated()
    } catch let error as BenchmarkValidationError {
      fail(error.localizedDescription)
    } catch {
      fail("could not read the benchmark plan; generate one with bench template and check its JSON fields")
    }
    let accounts = BenchmarkCLIAccounts(paths: LinuxPaths())
    let redactor: BenchmarkRedactor
    do {
      redactor = try await accounts.prepare(plan: plan)
    } catch {
      fail("a selected quota account is missing, disabled, incomplete or managed by the macOS app; check accounts list and use the full account ID")
    }
    let runner = BenchmarkRunner()
    let task = Task {
      try await runner.run(plan: plan, directory: directory, redactor: redactor,
                           credentialSource: { await accounts.currentRedactor() },
                           quotaReader: { id in try await accounts.read(id: id) },
                           update: { _, message in benchmarkProgress(message) })
    }
    installShutdownHandlers { task.cancel() }
    do {
      benchmarkPrintJSON(BenchmarkCLIResult(report: try await task.value))
    } catch let error as BenchmarkValidationError {
      fail(error.localizedDescription)
    } catch let error as BenchmarkError {
      fail(error.localizedDescription)
    } catch is CancellationError {
      fail("benchmark cancelled before any trial was recorded")
    } catch {
      fail("the benchmark could not complete; check the repository, executables and benchmark folder permissions")
    }
  case "list":
    guard arguments.count == 1 else { fail("bench list takes no arguments") }
    do {
      let reports = try BenchmarkReportStore(directory: directory).list()
      benchmarkPrintJSON(reports.map(BenchmarkCLIReportInfo.init))
    } catch {
      fail("could not read benchmark history; check the Benchmarks directory for unreadable or invalid reports")
    }
  case "show":
    guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { fail("bench show needs a report UUID") }
    do {
      guard let report = try BenchmarkReportStore(directory: directory).load(id: id) else { fail("benchmark report not found") }
      benchmarkPrintJSON(BenchmarkCLIResult(report: report))
    } catch {
      fail("could not read the benchmark report")
    }
  case "help", "--help", "-h":
    benchmarkUsage()
  default:
    fail("unknown bench command; use bench help")
  }
}

private func benchmarkUsage() {
  print("""
  Usage:
    llimit bench template
    llimit bench run <plan.json> --exclusive-accounts
    llimit bench list
    llimit bench show <report-UUID>

  Edit the template before running. Each trial starts from the repository's
  committed HEAD; uncommitted and ignored files are excluded. Commands use the
  CLI's own login, not LLimit's managed profiles. Match that login to accountID.
  Use {prompt} in an argument, or receive the prompt on standard input.

  Optional allowanceCost allocates a monetary cost to 100% of quotaMetricID;
  it is an estimate in the plan currency, not a provider charge. Overlapping
  quota windows are kept separate. Set settleSeconds for reporting delays.
  Reports and trial workspaces stay in the local private Benchmarks directory.
  """)
}

private func benchmarkTemplate() -> BenchmarkPlan {
  let environment = ProcessInfo.processInfo.environment
  func path(_ cli: ManagedCLI, fallback: String) -> String {
    cli.candidates(environment: environment).first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path ?? fallback
  }
  let codex = path(.codex, fallback: "/usr/local/bin/codex")
  let claude = path(.claude, fallback: "/usr/local/bin/claude")
  return BenchmarkPlan(
    taskPrompt: "Replace this with a coding task and its expected behavior.",
    rubric: "Assess functional correctness, completeness, maintainability and instruction following. Explain evidence and limitations.",
    repositoryPath: FileManager.default.currentDirectoryPath,
    candidates: [
      BenchmarkCandidate(name: "Codex (configured model)",
                         command: BenchmarkCommand(executable: codex, arguments: ["exec", "--json", "--sandbox", "workspace-write", "-"], outputFormat: .codexJSON)),
      BenchmarkCandidate(name: "Claude Code (configured model)",
                         command: BenchmarkCommand(executable: claude, arguments: ["-p", "--output-format", "json", "--permission-mode", "acceptEdits"], outputFormat: .claudeJSON))
    ], judges: [
      BenchmarkJudge(name: "Codex judge (configured model)",
                     command: BenchmarkCommand(executable: codex, arguments: ["exec", "--json", "--sandbox", "read-only", "-"], outputFormat: .codexJSON)),
      BenchmarkJudge(name: "Claude Code judge (configured model)",
                     command: BenchmarkCommand(executable: claude, arguments: ["-p", "--output-format", "json", "--tools", ""], outputFormat: .claudeJSON))
    ])
}

private func benchmarkProgress(_ text: String) {
  FileHandle.standardError.write(Data((text + "\n").utf8))
}

private func benchmarkPrintJSON<T: Encodable>(_ value: T) {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  do {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fail("could not encode benchmark output")
  }
}

private struct BenchmarkCLIReportInfo: Encodable {
  let id: UUID
  let startedAt: Date
  let finishedAt: Date?
  let baselineCommit: String
  let attempts: Int
  let summaries: [BenchmarkSummary]

  init(_ report: BenchmarkReport) {
    id = report.id
    startedAt = report.startedAt
    finishedAt = report.finishedAt
    baselineCommit = report.baselineCommit
    attempts = report.runs.count
    summaries = report.summaries
  }
}

private struct BenchmarkCLIResult: Encodable {
  let report: BenchmarkReport
  var summaries: [BenchmarkSummary] { report.summaries }

  private enum CodingKeys: String, CodingKey { case report, summaries }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(report, forKey: .report)
    try container.encode(summaries, forKey: .summaries)
  }
}

/// Reads only the selected quota account. It never copies credentials into an
/// agent process or polls unrelated accounts as a side effect of a measurement.
private actor BenchmarkCLIAccounts {
  private let daemon: QuotaDaemon
  private let coordinator = QuotaCoordinator.live()
  private var providers: [String: QuotaProvider] = [:]
  private var credentials: [String: [String: String]] = [:]
  private var quotaAttempts: [String: Date] = [:]

  init(paths: LinuxPaths) {
    daemon = QuotaDaemon(paths: paths, log: { _ in })
  }

  func prepare(plan: BenchmarkPlan) throws -> BenchmarkRedactor {
    try reload()
    for id in Set(plan.candidates.compactMap(\.accountID)) {
      let account = try selectedAccount(id: id)
      providers[id] = account.provider
      credentials[id] = account.credentials
    }
    return BenchmarkRedactor(configurations: daemon.settings.accounts.map { $0.runtimeConfiguration() })
  }

  func read(id: String) async throws -> ProviderUsage {
    try Task.checkCancellation()
    try reload()
    let account = try selectedAccount(id: id)
    guard providers[id] == account.provider, credentials[id] == account.credentials else { throw BenchmarkError.changedAccount }
    let lastObservation = daemon.snapshot?.providers.first(where: { $0.accountID == id && $0.provider == account.provider })?.fetchedAt
    let delay = BenchmarkQuotaCadence.delay(provider: account.provider, lastAttempt: quotaAttempts[id], lastObservation: lastObservation)
    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    let began = Date()
    quotaAttempts[id] = began
    let result = await coordinator.refresh(configurations: [account.runtimeConfiguration()], now: began)
    try Task.checkCancellation()
    try reload()
    let latest = try selectedAccount(id: id)
    // Reimport or account edits during a request invalidate its measurement.
    guard latest.provider == account.provider && latest.credentials == account.credentials else { throw BenchmarkError.changedAccount }
    guard !result.failures.contains(where: { $0.accountID == id }),
          let usage = result.providers.first(where: { $0.accountID == id && $0.provider == account.provider }),
          usage.fetchedAt >= began else { throw BenchmarkError.unavailableAccount }
    return usage
  }

  func currentRedactor() -> BenchmarkRedactor {
    // Retain the last successfully loaded settings if a concurrent edit cannot
    // be read; the runner also retains every previously observed secret.
    let previous = daemon.settings.accounts.map { $0.runtimeConfiguration() }
    do {
      try reload()
      return BenchmarkRedactor(configurations: daemon.settings.accounts.map { $0.runtimeConfiguration() })
    } catch {
      return BenchmarkRedactor(configurations: previous)
    }
  }

  private func reload() throws {
    try daemon.settingsLock.withLock { daemon.loadConfiguration(access: .inspect) }
    if let error = daemon.settingsLoadError { throw error }
  }

  private func selectedAccount(id: String) throws -> ProviderAccount {
    guard let account = daemon.settings.accounts.first(where: { $0.id == id }), account.isEnabled,
          account.provider.hasRequiredCredentials(account.runtimeConfiguration().credentials),
          !CodexAccountProfile.isManaged(account.credentials),
          account.credentials[CredentialField.anthropicCredentialSource] != ClaudeCodeCredentialSource.managedProfile.rawValue else {
      throw BenchmarkError.unavailableAccount
    }
    return account
  }
}
