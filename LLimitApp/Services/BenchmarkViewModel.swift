import AppKit
import Combine
import Foundation
import QuotaCore
import UniformTypeIdentifiers

@MainActor
final class BenchmarkViewModel: ObservableObject {
  @Published var plan: BenchmarkPlan
  @Published private(set) var reports: [BenchmarkReport] = []
  @Published private(set) var report: BenchmarkReport?
  @Published private(set) var isRunning = false
  @Published private(set) var progress = ""
  @Published private(set) var errorMessage: String?
  private weak var model: AppModel?
  private let directory: URL
  private let runner = BenchmarkRunner()
  private let harnessDiscovery = BenchmarkHarnessDiscovery()
  private var task: Task<Void, Never>?

  init(model: AppModel) {
    self.model = model
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    directory = support.appendingPathComponent("LLimit/Benchmarks", isDirectory: true)
    plan = BenchmarkPlan(taskPrompt: "", rubric: "The solution meets all task requirements, passes the acceptance check, and makes focused, maintainable changes.",
      repositoryPath: "", candidates: [BenchmarkCandidate(name: "Codex", command: Self.codexCommand(judge: false))],
      judges: [BenchmarkJudge(name: "Codex judge", command: Self.codexCommand(judge: true)),
               BenchmarkJudge(name: "Claude judge", command: BenchmarkCommand(executable: Self.defaultExecutable(named: "claude"),
                 arguments: ["-p", "--output-format", "json", "--tools", ""], outputFormat: .claudeJSON))])
    do {
      reports = try BenchmarkReportStore(directory: directory).list()
      if let latest = reports.first { plan = latest.plan; report = latest }
    } catch { errorMessage = "Could not load saved benchmarks. Check the benchmark folder's permissions." }
  }

  static func defaultExecutable(named name: String) -> String {
    let environment = ProcessInfo.processInfo.environment
    let candidates: [URL]
    switch name {
    case "codex": candidates = ManagedCLI.codex.candidates(environment: environment)
    case "claude": candidates = ManagedCLI.claude.candidates(environment: environment)
    default:
      let home = FileManager.default.homeDirectoryForCurrentUser
      let harnessPaths = name == "opencode" ? [home.appendingPathComponent(".opencode/bin").path] : []
      let paths = harnessPaths + [home.appendingPathComponent(".local/bin").path,
                   "/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
      candidates = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    }
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })?.path ?? "/usr/local/bin/\(name)"
  }

  func discoverHarnessModels(harness: BenchmarkHarness, executable: String,
                             plugins: BenchmarkHarnessPluginPolicy, repositoryPath: String) async throws -> [BenchmarkHarnessModel] {
    guard executable.hasPrefix("/"), !executable.contains("\0") else { throw BenchmarkHarnessError.invalidExecutable }
    let repository = repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard repository.isEmpty || repository.hasPrefix("/") else { throw BenchmarkError.invalidRepository }
    return try await harnessDiscovery.models(for: harness, executable: URL(fileURLWithPath: executable),
      repository: repository.isEmpty ? nil : URL(fileURLWithPath: repository, isDirectory: true), plugins: plugins)
  }

  private static func codexCommand(judge: Bool) -> BenchmarkCommand {
    BenchmarkCommand(executable: defaultExecutable(named: "codex"),
      arguments: ["exec", "--json", "--sandbox", judge ? "read-only" : "workspace-write", "-"], outputFormat: .codexJSON)
  }

  func start() {
    guard !isRunning, let model else { return }
    do { _ = try plan.validated() }
    catch { errorMessage = error.localizedDescription; return }
    guard !model.isRefreshing else { errorMessage = BenchmarkError.busy.localizedDescription; return }
    let selected = Set(plan.candidates.compactMap(\.accountID))
    guard selected.allSatisfy({ id in model.providerAccounts.contains { $0.id == id && $0.isEnabled && $0.hasRequiredCredentials } }) else {
      errorMessage = "Enable and connect each selected quota account before starting."
      return
    }
    let revisions = Dictionary(uniqueKeysWithValues: selected.map { ($0, model.benchmarkRevision(accountID: $0)) })
    let redactor = BenchmarkRedactor(configurations: model.providerAccounts.map { $0.runtimeConfiguration() })
    var pricedPlan = plan
    for index in pricedPlan.candidates.indices {
      let id = pricedPlan.candidates[index].accountID
      pricedPlan.candidates[index].subscriptionPricing = model.providerAccounts.first { $0.id == id }?.subscriptionPricing
    }
    let frozen = pricedPlan
    isRunning = true
    errorMessage = nil
    progress = "Preparing benchmark"
    report = nil
    task = Task { [self, model] in
      defer { isRunning = false; task = nil }
      do {
        report = try await runner.run(plan: frozen, directory: directory, redactor: redactor,
          credentialSource: { [model] in
            await MainActor.run { BenchmarkRedactor(configurations: model.providerAccounts.map { $0.runtimeConfiguration() }) }
          },
          quotaReader: { [model] id in
            try await MainActor.run {
              guard model.benchmarkRevision(accountID: id) == (revisions[id] ?? nil) else { throw BenchmarkError.changedAccount }
            }
            let reading = try await model.benchmarkUsage(accountID: id)
            try await MainActor.run {
              guard model.benchmarkRevision(accountID: id) == (revisions[id] ?? nil) else { throw BenchmarkError.changedAccount }
            }
            return reading
          }, update: { [self] report, progress in
            await MainActor.run { self.report = report; self.progress = progress }
          })
        reports = try BenchmarkReportStore(directory: directory).list()
      } catch is CancellationError { progress = "Cancelled" }
      catch {
        errorMessage = (error as? BenchmarkError)?.localizedDescription ?? "The benchmark could not start or save its results. Check the repository, executables and benchmark folder."
        progress = "Benchmark stopped"
        reports = (try? BenchmarkReportStore(directory: directory).list()) ?? reports
      }
    }
  }

  func cancel() { task?.cancel(); progress = "Stopping benchmark" }

  func stopAndWait() async { task?.cancel(); await task?.value }

  func loadReport(_ report: BenchmarkReport) {
    guard !isRunning else { return }
    self.report = report
    plan = report.plan
    errorMessage = nil
  }

  func exportReport() {
    guard let report else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "llimit-benchmark-\(report.id.uuidString).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { errorMessage = "Could not export the benchmark report." }
  }

  func revealArtifacts() {
    guard let report else { return }
    NSWorkspace.shared.open(directory.appendingPathComponent(report.id.uuidString, isDirectory: true))
  }
}
