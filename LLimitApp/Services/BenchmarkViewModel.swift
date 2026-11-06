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
  @Published private(set) var isReevaluating = false
  @Published private(set) var progress = ""
  @Published private(set) var executionProgress: BenchmarkProgress?
  @Published private(set) var executionEndedAt: Date?
  @Published private(set) var errorMessage: String?
  @Published private(set) var isCheckingAcceptance = false
  @Published private(set) var acceptanceCheckResult: BenchmarkAcceptanceCheckResult?
  @Published private(set) var acceptanceCheckError: String?
  private weak var model: AppModel?
  private let directory: URL
  private let draftStore: BenchmarkDraftStore
  private let runner = BenchmarkRunner()
  private let harnessDiscovery = BenchmarkHarnessDiscovery()
  private let acceptanceCheck = BenchmarkAcceptanceCheck()
  private var task: Task<Void, Never>?
  private var draftSubscriptions: Set<AnyCancellable> = []
  private var draftNeedsSaving = false
  private static let draftLoadError = "Could not load the saved benchmark setup. The draft has been left unchanged."
  private static let draftSaveError = "Could not save the benchmark setup. Check LLimit's local storage permissions."

  init(model: AppModel) {
    self.model = model
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    directory = support.appendingPathComponent("LLimit/Benchmarks", isDirectory: true)
    // Reports are redacted for display; the private draft preserves exact model
    // identifiers, task text and incomplete edits independently of that history.
    draftStore = BenchmarkDraftStore(fileURL: support.appendingPathComponent("LLimit/benchmark-draft.json"))
    plan = BenchmarkPlan(taskPrompt: "", rubric: "The solution meets all task requirements, passes the acceptance check, and makes focused, maintainable changes.",
      repositoryPath: "", candidates: [BenchmarkCandidate(name: "Codex", command: Self.codexCommand(judge: false))],
      judges: [BenchmarkJudge(name: "Codex judge", command: Self.codexCommand(judge: true)),
               BenchmarkJudge(name: "Claude judge", command: BenchmarkCommand(executable: Self.defaultExecutable(named: "claude"),
                 arguments: ["-p", "--output-format", "json", "--tools", ""], outputFormat: .claudeJSON))])
    do {
      reports = try BenchmarkReportStore(directory: directory).list()
      if let latest = reports.first { report = latest }
    } catch { errorMessage = "Could not load saved benchmarks. Check the benchmark folder's permissions." }
    var canSaveUpgradedDraft = true
    do {
      if let draft = try draftStore.load() { plan = draft }
      else if let latest = reports.first { plan = latest.plan }
    } catch { canSaveUpgradedDraft = false; errorMessage = Self.draftLoadError }
    let upgraded = Self.enablingJudgeInspection(in: plan)
    if upgraded != plan {
      plan = upgraded
      if canSaveUpgradedDraft {
        do { try draftStore.save(plan) }
        catch { errorMessage = Self.draftSaveError }
      }
    }

    $plan.removeDuplicates().dropFirst()
      .handleEvents(receiveOutput: { [weak self] _ in self?.draftNeedsSaving = true })
      .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
      .sink { [weak self] _ in self?.saveDraftIfNeeded() }
      .store(in: &draftSubscriptions)
    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      .sink { [weak self] _ in self?.saveDraftIfNeeded() }
      .store(in: &draftSubscriptions)
  }

  static func defaultExecutable(named name: String) -> String {
    let environment = ProcessInfo.processInfo.environment
    let candidates: [URL]
    switch name {
    case "codex": candidates = ManagedCLI.codex.candidates(environment: environment)
    case "claude": candidates = ManagedCLI.claude.candidates(environment: environment)
    default:
      let home = FileManager.default.homeDirectoryForCurrentUser
      var paths: [String] = []
      if name == "opencode" { paths.append(home.appendingPathComponent(".opencode/bin").path) }
      paths.append(contentsOf: [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"])
      let searchPath = (environment["PATH"] ?? "").split(separator: ":").map { String($0) }
      paths.append(contentsOf: searchPath)
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

  private static func enablingJudgeInspection(in original: BenchmarkPlan) -> BenchmarkPlan {
    var plan = original
    plan.judges = original.judges.map {
      var judge = $0
      judge.command = BenchmarkJudgeInspection.enablingInspection(in: judge.command) ?? judge.command
      return judge
    }
    return plan
  }

  func checkAcceptanceCommand() {
    guard !isRunning, !isCheckingAcceptance, let model else { return }
    let command = plan.acceptanceCommand ?? ""
    let repository = plan.repositoryPath
    let timeout = plan.timeoutSeconds
    let redactor = BenchmarkRedactor(configurations: model.providerAccounts.map { $0.runtimeConfiguration() })
    isCheckingAcceptance = true
    acceptanceCheckResult = nil
    acceptanceCheckError = nil
    task = Task { [self, model] in
      defer { isCheckingAcceptance = false; task = nil }
      do {
        let result = try await acceptanceCheck.check(repository: URL(fileURLWithPath: repository), command: command,
          timeout: timeout, redactor: redactor, credentialSource: { [model] in
            await MainActor.run { BenchmarkRedactor(configurations: model.providerAccounts.map { $0.runtimeConfiguration() }) }
          })
        guard plan.repositoryPath == repository, plan.acceptanceCommand == command else { return }
        acceptanceCheckResult = result
      } catch is CancellationError { acceptanceCheckError = "Baseline check cancelled." }
      catch { acceptanceCheckError = "The baseline check could not run. Check the repository, command and timeout." }
    }
  }

  func clearAcceptanceCheck() {
    acceptanceCheckResult = nil
    acceptanceCheckError = nil
  }

  func cancelAcceptanceCheck() {
    guard isCheckingAcceptance else { return }
    task?.cancel()
  }

  func start() {
    guard !isRunning, !isCheckingAcceptance, let model else { return }
    do { _ = try plan.validated() }
    catch { errorMessage = error.localizedDescription; return }
    guard !model.isRefreshing else { errorMessage = BenchmarkError.busy.localizedDescription; return }
    let selected = Set(plan.candidates.compactMap(\.accountID))
    guard selected.allSatisfy({ id in model.providerAccounts.contains { $0.id == id && $0.isEnabled && $0.hasRequiredCredentials } }) else {
      errorMessage = "Enable and connect each selected quota account before starting."
      return
    }
    guard saveDraftIfNeeded(force: true) else { return }
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
    executionProgress = nil
    executionEndedAt = nil
    report = nil
    task = Task { [self, model] in
      defer { executionEndedAt = Date(); isRunning = false; task = nil }
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
          }, progress: { [self] progress in
            await MainActor.run { self.executionProgress = progress }
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

  var canReevaluateReport: Bool {
    !isRunning && !isCheckingAcceptance && report?.finishedAt != nil && report?.runs.contains(where: { $0.outcome == .completed }) == true
  }

  func reevaluateReport() {
    guard canReevaluateReport, let original = report, let model else { return }
    guard !model.isRefreshing else { errorMessage = BenchmarkError.busy.localizedDescription; return }
    let judges = original.plan.judges.map { saved in
      var judge = plan.judges.first { $0.id == saved.id } ?? saved
      judge.command = BenchmarkJudgeInspection.enablingInspection(in: judge.command) ?? judge.command
      return judge
    }
    guard !judges.contains(where: { $0.command.arguments.contains { $0.contains("[redacted]") } }) else {
      errorMessage = "Update the judge commands in benchmark setup before re-evaluating; a saved command contains redacted values."
      return
    }
    let redactor = BenchmarkRedactor(configurations: model.providerAccounts.map { $0.runtimeConfiguration() })
    isRunning = true
    isReevaluating = true
    errorMessage = nil
    progress = "Recovering saved results"
    executionProgress = nil
    executionEndedAt = nil
    task = Task { [self, model] in
      defer { executionEndedAt = Date(); isRunning = false; isReevaluating = false; task = nil }
      do {
        report = try await runner.reevaluate(report: original, directory: directory, judges: judges, redactor: redactor,
          credentialSource: { [model] in
            await MainActor.run { BenchmarkRedactor(configurations: model.providerAccounts.map { $0.runtimeConfiguration() }) }
          }, progress: { [self] state in
            await MainActor.run { self.executionProgress = state }
          }, update: { [self] report, message in
            await MainActor.run { self.report = report; self.progress = message }
          })
        reports = try BenchmarkReportStore(directory: directory).list()
      } catch is CancellationError { progress = "Re-evaluation cancelled" }
      catch {
        errorMessage = error.localizedDescription
        progress = "Re-evaluation stopped"
        reports = (try? BenchmarkReportStore(directory: directory).list()) ?? reports
      }
    }
  }

  func stopAndWait() async {
    saveDraftIfNeeded()
    task?.cancel()
    await task?.value
  }

  @discardableResult
  private func saveDraftIfNeeded(force: Bool = false) -> Bool {
    guard force || draftNeedsSaving else { return true }
    do {
      try draftStore.save(plan)
      draftNeedsSaving = false
      if errorMessage == Self.draftSaveError || errorMessage == Self.draftLoadError { errorMessage = nil }
      return true
    } catch {
      errorMessage = Self.draftSaveError
      return false
    }
  }

  func loadReport(_ report: BenchmarkReport) {
    guard !isRunning, !isCheckingAcceptance else { return }
    self.report = report
    executionProgress = nil
    // History selects a result, not an editable setup. Redacted archive text
    // must never overwrite the private task, model IDs or judge permissions.
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
    NSWorkspace.shared.open(directory.appendingPathComponent((report.artifactReportID ?? report.id).uuidString, isDirectory: true))
  }
}
