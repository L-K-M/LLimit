import AppKit
import SwiftUI
import QuotaCore

struct BenchmarksView: View {
  @ObservedObject private var model: AppModel
  @ObservedObject private var benchmark: BenchmarkViewModel
  @State private var accountsConfirmed = false
  @State private var invalidEditors: Set<UUID> = []
  @State private var isSetupExpanded = true
  @State private var isAttemptDetailsExpanded = false
  @State private var resultsFocusRequest = UUID()
  @State private var confirmsReevaluation = false
  private let resultsAnchor = "benchmark-results-overview"

  private var readiness: BenchmarkReadiness {
    BenchmarkReadiness(plan: benchmark.plan, accountUseConfirmed: accountsConfirmed, invalidEditorIDs: invalidEditors)
  }

  init(model: AppModel) {
    self.model = model
    self.benchmark = model.benchmarks
  }

  var body: some View {
    VStack(spacing: 0) {
      if benchmark.isRunning {
        progressPanel
          .padding(20)
          .background(.bar)
        Divider()
      }
      ScrollViewReader { scroll in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            header
            if let error = benchmark.errorMessage {
              Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }
            DisclosureGroup("Benchmark setup", isExpanded: $isSetupExpanded) {
              setup.disabled(benchmark.isRunning)
                .padding(.top, 12)
            }
            if let report = benchmark.report {
              reportSection(report)
                .id(resultsAnchor)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(24)
        }
        .onAppear {
          if benchmark.isRunning { isSetupExpanded = false }
          else { focusResults(scroll) }
        }
        .onChange(of: benchmark.isRunning) { _, running in
          if running { isSetupExpanded = false }
          else { focusResults(scroll) }
        }
        .onChange(of: benchmark.report?.id) { _, _ in
          if !benchmark.isRunning { focusResults(scroll) }
        }
        .onChange(of: resultsFocusRequest) { _, _ in
          focusResults(scroll)
        }
      }
    }
    .confirmationDialog("Re-evaluate saved results?", isPresented: $confirmsReevaluation, titleVisibility: .visible) {
      Button("Re-evaluate saved results") { benchmark.reevaluateReport() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The two judges create a new report, keeping the original in history. Only judges run again and consume quota. The original agent work, execution times, and costs are reused.")
    }
  }

  private func focusResults(_ scroll: ScrollViewProxy) {
    guard !benchmark.isRunning, benchmark.report != nil else { return }
    isSetupExpanded = false
    isAttemptDetailsExpanded = false
    // Collapse the setup before locating the overview in the new layout.
    DispatchQueue.main.async {
      scroll.scrollTo(resultsAnchor, anchor: .top)
    }
  }

  private var progressPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(progressTitle).font(.headline)
        Spacer()
        if let state = benchmark.executionProgress {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let end = benchmark.isRunning ? context.date : benchmark.report?.finishedAt ?? benchmark.executionEndedAt ?? context.date
            Text("Elapsed \(elapsed(end.timeIntervalSince(state.startedAt)))")
              .font(.caption).monospacedDigit().foregroundStyle(.secondary)
          }
        }
        if benchmark.isRunning {
          Button("Cancel", role: .cancel) { benchmark.cancel() }
            .disabled(benchmark.progress == "Stopping benchmark")
        }
      }
      Text(benchmark.progress).font(.callout)
      if let state = benchmark.executionProgress {
        ProgressView(value: state.attemptFraction)
          .accessibilityLabel("Attempts completed")
          .accessibilityValue("\(state.completedAttempts) of \(state.totalAttempts)")
        Text("\(state.completedAttempts) of \(state.totalAttempts) attempts finished")
          .font(.caption).foregroundStyle(.secondary)
        if state.phase == .evaluating || state.completedEvaluations > 0 || state.isTerminal && state.totalEvaluations > 0 {
          ProgressView(value: state.evaluationFraction)
            .accessibilityLabel("Evaluations completed")
            .accessibilityValue("\(state.completedEvaluations) of \(state.totalEvaluations)")
          Text("\(state.completedEvaluations) of \(state.totalEvaluations) evaluations finished")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      if benchmark.isRunning {
        Text("The benchmark keeps running when this window closes. Reopen it from Settings > Benchmarks to check progress.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var progressTitle: String {
    if benchmark.isReevaluating { return "Re-evaluating saved results" }
    if !benchmark.isRunning, let state = benchmark.executionProgress, !state.isTerminal { return "Benchmark stopped" }
    switch benchmark.executionProgress?.phase {
    case .preparing, nil: return "Preparing benchmark"
    case .runningTrial: return "Running agents"
    case .waitingForQuota: return "Measuring quota"
    case .checkingAcceptance: return "Checking acceptance"
    case .evaluating: return "Evaluating results"
    case .completed: return "Benchmark complete"
    case .cancelled: return "Benchmark cancelled"
    }
  }

  private func elapsed(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Benchmarks").font(.title2.weight(.semibold))
        Spacer()
        if !benchmark.reports.isEmpty {
          Menu {
            ForEach(benchmark.reports, id: \.id) { report in
              Button(report.startedAt.formatted(date: .abbreviated, time: .shortened)) {
                benchmark.loadReport(report)
                resultsFocusRequest = UUID()
              }
            }
          } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
          }
          .disabled(benchmark.isRunning || benchmark.isCheckingAcceptance)
        }
      }
      Text("Compare the time, quota, and output quality of your agent setups on the same task.")
        .foregroundStyle(.secondary)
    }
  }

  private var setup: some View {
    VStack(alignment: .leading, spacing: 18) {
      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          fieldTitle("Task")
          promptEditor($benchmark.plan.taskPrompt, height: 100)
          fieldTitle("Acceptance criteria")
          promptEditor($benchmark.plan.rubric, height: 80)
          Text("Both judges use these criteria. Describe correctness, required behavior, and what would make a result unacceptable.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            TextField("Repository folder", text: $benchmark.plan.repositoryPath)
            Button("Choose…") { chooseRepository() }
          }
          Text("Each attempt starts from the repository's committed HEAD. Commit the inputs you want included before starting. Claude quota reads are spaced at least three minutes apart.")
            .font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 18) {
            Stepper("Repetitions: \(benchmark.plan.repetitions)", value: $benchmark.plan.repetitions, in: 1...20)
            Spacer()
            TextField("Currency", text: $benchmark.plan.currency)
              .frame(width: 76)
              .help("Currency used for allocated cost estimates, for example USD or CHF.")
          }
          LabeledContent("Run timeout (seconds)") {
            TextField("600", value: $benchmark.plan.timeoutSeconds, format: .number)
              .frame(width: 85)
          }
          Text("Each attempt may run for up to 24 hours (86,400 seconds).")
            .font(.caption).foregroundStyle(.secondary)
          LabeledContent("Quota reporting delay (seconds)") {
            TextField("0", value: $benchmark.plan.settleSeconds, format: .number)
              .frame(width: 85)
          }
          acceptanceSetup
        }
        .padding(8)
      } label: {
        Label("Task and conditions", systemImage: "text.clipboard")
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          ForEach($benchmark.plan.candidates, id: \.id) { $candidate in
            BenchmarkCandidateEditor(
              candidate: $candidate,
              benchmark: benchmark,
              repositoryPath: benchmark.plan.repositoryPath,
              accounts: model.providerAccounts,
              usages: model.snapshot?.providers ?? [],
              reportCurrency: benchmark.plan.currency,
              onValidity: { setValidity(candidate.id, valid: $0) },
              onRemove: { removeCandidate(candidate.id) }
            )
            Divider()
          }
          Menu {
            ForEach(BenchmarkCLIPreset.allCases) { preset in
              Button(preset.title) {
                benchmark.plan.candidates.append(BenchmarkCandidate(
                  name: preset.title, command: preset.command(judge: false)
                ))
              }
            }
          } label: {
            Label("Add agent", systemImage: "plus")
          }
          .disabled(benchmark.plan.candidates.count >= 10)
          Text("Each CLI uses its own existing login. Match it to the quota account you select. LLimit's private managed logins are separate.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
      } label: {
        Label("Agents", systemImage: "terminal")
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          Text("Two judges assess each result independently. Agent identity and cost are hidden from their prompts.")
            .font(.callout).foregroundStyle(.secondary)
          ForEach($benchmark.plan.judges, id: \.id) { $judge in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                TextField("Judge name", text: $judge.name)
                Menu("Preset") {
                  ForEach(BenchmarkCLIPreset.allCases) { preset in
                    Button(preset.title) { judge.command = preset.command(judge: true) }
                  }
                }
              }
              BenchmarkCommandEditor(command: $judge.command, benchmark: benchmark,
                                     repositoryPath: benchmark.plan.repositoryPath, judge: true) {
                setValidity(judge.id, valid: $0)
              }
              if BenchmarkJudgeInspection.enablingInspection(in: judge.command) == judge.command {
                Text("File inspection enabled. LLimit runs the configured test command independently and supplies its results.")
                  .font(.caption).foregroundStyle(.secondary)
              } else {
                Text("Custom judge command. Check its file permissions in Advanced command; tests run through the acceptance command.")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            if judge.id != benchmark.plan.judges.last?.id { Divider() }
          }
          Text("Pi and OpenCode can list configured providers and models. Other CLIs use their model arguments. Judge time is reported separately from agent execution.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
      } label: {
        Label("Judges", systemImage: "checkmark.bubble")
      }

      Toggle("The CLI logins match the selected accounts, and these accounts are idle elsewhere.", isOn: $accountsConfirmed)
        .toggleStyle(.checkbox)
        .font(.callout)
      if !benchmark.isRunning, !readiness.isReady {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(readiness.reasons.enumerated()), id: \.offset) { _, reason in
            Label(reason, systemImage: "exclamationmark.circle")
              .font(.caption).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      HStack {
        Button {
          accountsConfirmed = false
          benchmark.start()
        } label: {
          Label("Run benchmark", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!readiness.isReady || benchmark.isCheckingAcceptance)
        .help(readiness.reasons.first ?? "Run the configured benchmark.")
        Text("Runs agents and judges using their configured subscriptions or API accounts.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .textFieldStyle(.roundedBorder)
  }

  private var acceptanceSetup: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Acceptance test command, for example swift test", text: Binding(
        get: { benchmark.plan.acceptanceCommand ?? "" },
        set: { benchmark.plan.acceptanceCommand = $0.isEmpty ? nil : $0 }
      ), axis: .vertical)
      .font(.system(.body, design: .monospaced))
      .lineLimit(2...5)
      HStack {
        Button("Check on baseline") { benchmark.checkAcceptanceCommand() }
          .disabled(benchmark.isCheckingAcceptance || benchmark.plan.repositoryPath.isEmpty ||
                    (benchmark.plan.acceptanceCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if benchmark.isCheckingAcceptance {
          ProgressView().controlSize(.small)
          Text("Checking a disposable copy…").font(.caption)
          Button("Cancel") { benchmark.cancelAcceptanceCheck() }
        }
      }
      Text("Runs independently in each attempt's checkout before judging. A failed command rejects that result. Check on baseline tests a fresh copy of committed HEAD first, without running agents or judges.")
        .font(.caption).foregroundStyle(.secondary)
      if (benchmark.plan.acceptanceCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Label("No test command configured. Test results reported by agents will remain unverified.", systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let result = benchmark.acceptanceCheckResult {
        Label(result.passed ? "Baseline check passed" : result.timedOut ? "Baseline check timed out" : "Baseline check failed (exit \(result.exitCode))",
              systemImage: result.passed ? "checkmark.circle" : "exclamationmark.triangle")
          .font(.callout).foregroundStyle(result.passed ? Color.secondary : Color.orange)
        Text("Commit \(result.baselineCommit.prefix(12)). Candidate attempts will receive their own checks.")
          .font(.caption).foregroundStyle(.secondary)
        if !result.passed && !result.timedOut {
          Text("The baseline already fails this command. An attempt must resolve the failures to pass the same check.")
            .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Baseline check output") {
          Text(result.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
      }
      if let error = benchmark.acceptanceCheckError {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
      }
    }
    .onChange(of: benchmark.plan.acceptanceCommand) { _, _ in benchmark.clearAcceptanceCheck() }
    .onChange(of: benchmark.plan.repositoryPath) { _, _ in benchmark.clearAcceptanceCheck() }
  }

  private func reportSection(_ report: BenchmarkReport) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(benchmark.isRunning ? "Live results" : "Results overview")
          .font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button("Export JSON…") { benchmark.exportReport() }
        Button("Show files") { benchmark.revealArtifacts() }
      }
      Text(reportMetadata(report))
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if benchmark.canReevaluateReport || benchmark.isReevaluating {
        HStack(spacing: 10) {
          Button("Re-evaluate saved results…") { confirmsReevaluation = true }
            .disabled(!benchmark.canReevaluateReport || benchmark.isReevaluating)
            .help("Save new judge assessments in a new report using the original agent work, times, and costs.")
          if benchmark.isReevaluating {
            Text("Re-evaluating with both judges")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if report.reevaluationOf != nil {
        Text("Re-evaluated saved results. Agent work, execution times, and costs come from the original attempts; only the judge assessments are new.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if benchmark.isRunning {
        Text(benchmark.isReevaluating
          ? "Saved attempts are being evaluated again. Scores update as the judges finish."
          : "Attempts are still running. Results appear as they finish; quality scores follow the judge evaluations.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if report.runs.isEmpty {
        Text(benchmark.isRunning ? "No attempts have finished yet." : "No attempts were recorded.")
          .foregroundStyle(.secondary)
      } else {
        Text(evaluationOverview(report))
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        comparison(report)
      }
      if report.runs.contains(where: { $0.outcome == .completed && $0.evidence == nil && $0.patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        Label("Older evaluations with empty root diffs may omit local-branch or linked-worktree changes. Output-only tasks can still be valid. Re-evaluate to review any work still available.", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Costs allocate your subscription price and include failed attempts. Judge scores summarize the available evaluations; disagreements and missing evaluations require review.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Task and evaluation criteria") {
        VStack(alignment: .leading, spacing: 10) {
          fieldTitle("Task")
          Text(report.plan.taskPrompt)
          fieldTitle("Acceptance criteria")
          Text(report.plan.rubric)
          if let command = report.plan.acceptanceCommand {
            fieldTitle("Acceptance command")
            Text(command).font(.system(.callout, design: .monospaced))
          }
        }
        .font(.callout).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
      }
      if !report.warnings.isEmpty {
        DisclosureGroup("Measurement notes (\(report.warnings.count))") {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
              Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.top, 8)
        }
      }
      DisclosureGroup("Attempt details (\(report.runs.count))", isExpanded: $isAttemptDetailsExpanded) {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(report.runs, id: \.id) { run in
            runCard(run, report: report)
          }
        }
        .padding(.top, 8)
      }
    }
  }

  private func comparison(_ report: BenchmarkReport) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 12) {
      ForEach(report.summaries, id: \.candidateID) { summary in
        let runs = report.runs.filter { $0.candidateID == summary.candidateID }
        let coverage = BenchmarkCostCoverage(runs: runs)
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
              GridRow {
                resultMetric("Accepted", value: "\(summary.acceptedCount) / \(summary.attempts)")
                resultMetric("Median time", value: duration(summary.medianDurationSeconds))
                  .help("Range: \(duration(summary.minDurationSeconds)) to \(duration(summary.maxDurationSeconds))")
              }
              GridRow {
                resultMetric("Judge score / 10", value: summary.meanQualityScore.map { String(format: "%.1f", $0) } ?? "Unavailable")
                resultMetric(coverage.isComplete ? "Allocated cost" : "Known allocated cost", value: money(coverage.knownCost, currency: report.plan.currency))
              }
              GridRow {
                resultMetric("Cost / accepted", value: money(summary.estimatedCostPerAcceptedTask, currency: report.plan.currency))
                resultMetric("Needs review", value: "\(runs.filter { assessment($0).needsReview || evidenceNeedsReview($0) }.count)")
              }
            }
            if !coverage.isComplete {
              Text("\(coverage.pricedAttempts) of \(coverage.totalAttempts) attempts priced; the full total is unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Text(outcomeSummary(runs))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        } label: {
          Text(summary.name).font(.headline)
        }
      }
    }
  }

  private func resultMetric(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.callout.weight(.semibold)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func runCard(_ run: BenchmarkRun, report: BenchmarkReport) -> some View {
    let candidate = report.plan.candidates.first { $0.id == run.candidateID }
    return DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 14) {
          Text("Execution: \(run.outcome.rawValue)")
          if let passed = run.acceptancePassed {
            Text(passed ? "Acceptance command passed" : "Acceptance command failed")
          }
        }
        .font(.caption).foregroundStyle(.secondary)
        if let reason = run.acceptanceUnavailableReason {
          Label(reason, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(run.quotaChanges.enumerated()), id: \.offset) { _, change in
          VStack(alignment: .leading, spacing: 2) {
            Text(quotaDescription(change)).font(.callout)
            if let reason = change.unavailableReason {
              Text(reason).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if let tokens = run.tokenUsage {
          Text("Reported tokens: \(tokens.inputTokens) input · \(tokens.cachedInputTokens) cached input · \(tokens.outputTokens) output")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let basis = run.costBasis {
          Text(basis).font(.caption).foregroundStyle(.secondary)
        }
        if let reason = BenchmarkCostCoverage.unavailableReason(for: run, candidate: candidate, currency: report.plan.currency) {
          Label("Cost unavailable: \(reason)", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let capture = run.evidence {
          Text("Workspace: \(capture.workspaceName)")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if !capture.captureComplete {
            Label("Work capture is incomplete. Judge conclusions may be based on only part of the result.", systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          }
          ForEach(Array(capture.warnings.enumerated()), id: \.offset) { _, warning in
            Text(warning).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          Text("This older attempt has no capture metadata for local branches or linked worktrees. Its saved diff and output may contain only part of the work.")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(run.evaluations.enumerated()), id: \.offset) { _, evaluation in
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
              if let error = evaluation.error { Text(error).foregroundStyle(.red) }
              if !evaluation.explanation.isEmpty { Text(evaluation.explanation).foregroundStyle(.secondary) }
            }
            .padding(.top, 6)
          } label: {
            HStack {
              let judgeName = report.plan.judges.first { $0.id == evaluation.judgeID }?.name ?? "Judge"
              Text(judgeName).fontWeight(.medium)
              if let score = evaluation.score { Text(String(format: "%.1f / 10", score)) }
              if let accepted = evaluation.accepted { Text(accepted ? "Accepted" : "Rejected") }
              if evaluation.error != nil { Text("Evaluation unavailable").foregroundStyle(.orange) }
            }
          }
          .font(.callout).textSelection(.enabled)
        }
        if !run.output.isEmpty {
          DisclosureGroup("Agent output") { evidence(run.output) }
        }
        if !run.patch.isEmpty {
          DisclosureGroup("Root workspace changes") { evidence(run.patch) }
        }
        if let capture = run.evidence {
          ForEach(Array(capture.additionalArtifacts.enumerated()), id: \.offset) { _, artifact in
            DisclosureGroup("\(artifact.kind == .localBranch ? "Local branch" : "Linked worktree") · \(artifact.name)") {
              if artifact.patch.isEmpty {
                Text("No diff was saved for this artifact.")
                  .font(.caption).foregroundStyle(.secondary)
              } else {
                evidence(artifact.patch)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    } label: {
      HStack(spacing: 12) {
        Text("\(candidate?.name ?? "Agent") · attempt \(run.repetition)")
          .fontWeight(.medium)
        Spacer(minLength: 4)
        Text(assessment(run).label).foregroundStyle(.secondary)
        Text(duration(run.durationSeconds)).monospacedDigit()
      }
      .font(.callout)
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  private func evidence(_ text: String) -> some View {
    ScrollView([.horizontal, .vertical]) {
      Text(text)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
    .frame(maxHeight: 280)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
  }

  private func fieldTitle(_ title: String) -> some View {
    Text(title).font(.subheadline.weight(.medium))
  }

  private func promptEditor(_ text: Binding<String>, height: CGFloat) -> some View {
    TextEditor(text: text)
      .font(.body)
      .scrollContentBackground(.hidden)
      .padding(6)
      .frame(minHeight: height, maxHeight: height)
      .background(.background, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
  }

  private func chooseRepository() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose repository"
    if panel.runModal() == .OK, let url = panel.url {
      benchmark.plan.repositoryPath = url.path
    }
  }

  private func setValidity(_ id: UUID, valid: Bool) {
    if valid { invalidEditors.remove(id) } else { invalidEditors.insert(id) }
  }

  private func removeCandidate(_ id: UUID) {
    benchmark.plan.candidates.removeAll { $0.id == id }
    invalidEditors.remove(id)
  }

  private func duration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite else { return "Unavailable" }
    if seconds >= 60 { return String(format: "%.1f min", seconds / 60) }
    return String(format: "%.1f sec", seconds)
  }

  private func money(_ value: Double?, currency: String) -> String {
    value.map { "\(currency) \(String(format: "%.4f", $0))" } ?? "Unavailable"
  }

  private func reportMetadata(_ report: BenchmarkReport) -> String {
    var parts = [report.startedAt.formatted(date: .abbreviated, time: .shortened), "commit \(report.baselineCommit.prefix(12))"]
    if let finished = report.finishedAt {
      let label = report.reevaluationOf == nil ? "Total" : "Re-evaluation"
      parts.append("\(label) \(duration(finished.timeIntervalSince(report.startedAt)))")
    }
    parts.append("Judging \(duration(report.judgeDurationSeconds))")
    return parts.joined(separator: " · ")
  }

  private enum RunAssessment: Equatable {
    case accepted, executionFailed, acceptanceFailed, acceptanceUnavailable, rejected, disagreement, incomplete

    var needsReview: Bool { self == .disagreement || self == .incomplete || self == .acceptanceUnavailable }

    var label: String {
      switch self {
      case .accepted: return "Accepted"
      case .executionFailed: return "Execution failed"
      case .acceptanceFailed: return "Acceptance check failed"
      case .acceptanceUnavailable: return "Acceptance check unavailable"
      case .rejected: return "Rejected by judges"
      case .disagreement: return "Judges disagree"
      case .incomplete: return "Evaluation incomplete"
      }
    }
  }

  private func assessment(_ run: BenchmarkRun) -> RunAssessment {
    guard run.outcome == .completed else { return .executionFailed }
    guard run.acceptanceUnavailableReason == nil else { return .acceptanceUnavailable }
    guard run.acceptancePassed != false else { return .acceptanceFailed }
    if run.isAccepted == true { return .accepted }
    if run.isAccepted == false { return .rejected }
    let valid = run.evaluations.filter(\.isValid)
    if valid.count == 2, Set(valid.map(\.judgeID)).count == 2,
       Set(valid.compactMap(\.accepted)).count == 2 {
      return .disagreement
    }
    return .incomplete
  }

  private func evaluationOverview(_ report: BenchmarkReport) -> String {
    let accepted = report.runs.filter { assessment($0) == .accepted }.count
    let unresolved = report.runs.filter { assessment($0).needsReview }.count
    let failures = report.runs.filter { assessment($0) == .executionFailed }.count
    if failures == report.runs.count {
      return "Every recorded agent execution failed. These results cannot establish output quality; inspect the attempt details."
    }
    let evidenceReview = report.runs.filter(evidenceNeedsReview).count
    if unresolved > 0 || evidenceReview > 0 {
      var concerns: [String] = []
      let disagreement = report.runs.filter { assessment($0) == .disagreement }.count
      let incomplete = report.runs.filter { assessment($0) == .incomplete }.count
      let unavailable = report.runs.filter { assessment($0) == .acceptanceUnavailable }.count
      if disagreement > 0 { concerns.append("judge disagreements: \(disagreement)") }
      if incomplete > 0 { concerns.append("incomplete evaluations: \(incomplete)") }
      if unavailable > 0 { concerns.append("acceptance checks unavailable: \(unavailable)") }
      if evidenceReview > 0 { concerns.append("\(evidenceReview) need evidence review") }
      return "\(accepted) of \(report.runs.count) attempts accepted; \(concerns.joined(separator: "; ")). Scores alone do not establish a reliable winner."
    }
    if accepted == 0 {
      return "No recorded attempt met the acceptance requirements. Review failed checks and judge decisions before choosing a setup."
    }
    return "\(accepted) of \(report.runs.count) attempts met the acceptance requirements. Compare accepted results alongside time and allocated cost."
  }

  private func outcomeSummary(_ runs: [BenchmarkRun]) -> String {
    guard !runs.isEmpty else { return "No attempts recorded" }
    let categories: [(RunAssessment, String, String)] = [
      (.executionFailed, "execution failure", "execution failures"),
      (.acceptanceFailed, "failed acceptance check", "failed acceptance checks"),
      (.acceptanceUnavailable, "unavailable acceptance check", "unavailable acceptance checks"),
      (.rejected, "judge rejection", "judge rejections"),
      (.disagreement, "judge disagreement", "judge disagreements"),
      (.incomplete, "incomplete evaluation", "incomplete evaluations")
    ]
    var details = categories.compactMap { category, singular, plural -> String? in
      let count = runs.filter { assessment($0) == category }.count
      return count > 0 ? "\(count) \(count == 1 ? singular : plural)" : nil
    }
    let evidenceReview = runs.filter(evidenceNeedsReview).count
    if evidenceReview > 0 { details.append("\(evidenceReview) need evidence review") }
    return details.isEmpty ? "All recorded attempts accepted" : details.joined(separator: " · ")
  }

  private func evidenceNeedsReview(_ run: BenchmarkRun) -> Bool {
    run.outcome == .completed && run.evidence?.captureComplete != true
  }

  private func quotaDescription(_ change: BenchmarkQuotaChange) -> String {
    var details: [String] = []
    if let amount = change.consumedAmount { details.append("\(amount.formatted()) units") }
    if let percent = change.consumedPercentagePoints {
      details.append("\(percent.formatted(.number.precision(.fractionLength(0...3)))) percentage points")
    }
    return "\(change.label): \(details.isEmpty ? "usage unavailable" : details.joined(separator: " · "))"
  }
}

private struct BenchmarkCandidateEditor: View {
  @Binding var candidate: BenchmarkCandidate
  @ObservedObject var benchmark: BenchmarkViewModel
  let repositoryPath: String
  let accounts: [ProviderAccount]
  let usages: [ProviderUsage]
  let reportCurrency: String
  let onValidity: (Bool) -> Void
  let onRemove: () -> Void
  @State private var commandValid = true
  @State private var allowanceDraft = ""
  @State private var allowanceError: String?

  private var metrics: [UsageMetric] {
    usages.first { $0.accountID == candidate.accountID }?.metrics ?? []
  }

  private var subscription: SubscriptionPricing? {
    accounts.first { $0.id == candidate.accountID }?.subscriptionPricing
  }

  private var provider: QuotaProvider? {
    accounts.first { $0.id == candidate.accountID }?.provider
  }

  private var subscriptionAllocation: BenchmarkPriceAllocation? {
    guard let price = subscription, let metric = metrics.first(where: { $0.id == candidate.quotaMetricID }) else { return nil }
    return BenchmarkPriceAllocation.subscription(price, metric: metric, currency: reportCurrency, provider: provider)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        TextField("Agent name", text: $candidate.name)
        Menu("Preset") {
          ForEach(BenchmarkCLIPreset.allCases) { preset in
            Button(preset.title) { candidate.command = preset.command(judge: false) }
          }
        }
        Button(role: .destructive, action: onRemove) {
          Image(systemName: "trash")
        }
        .help("Remove agent")
      }
      BenchmarkCommandEditor(command: $candidate.command, benchmark: benchmark,
                             repositoryPath: repositoryPath, judge: false) { valid in
        commandValid = valid
        reportValidity()
      }
      Picker("Quota account", selection: $candidate.accountID) {
        Text("No quota measurement").tag(String?.none)
        ForEach(accounts) { account in
          Text(account.resolvedDisplayName).tag(Optional(account.id))
        }
      }
      .onChange(of: candidate.accountID) { _, _ in
        candidate.quotaMetricID = subscription == nil ? nil : BenchmarkPriceAllocation.defaultMetricID(in: metrics, provider: provider)
        candidate.allowanceCost = nil
        allowanceDraft = ""
        allowanceError = nil
        reportValidity()
      }
      if candidate.accountID != nil {
        if let price = subscription {
          Text("Account subscription: \(price.amount.formatted(.currency(code: price.currency))) · \(price.billingPeriod.displayName.lowercased())")
            .font(.callout)
        } else {
          Text("Set this account's subscription cost in Settings → Accounts for automatic estimates.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Cost allocation window", selection: $candidate.quotaMetricID) {
          Text("No cost estimate").tag(String?.none)
          ForEach(metrics) { metric in
            Text(metric.label).tag(Optional(metric.id))
          }
        }
        LabeledContent("Full-window cost override (\(reportCurrency))") {
          TextField("Automatic", text: $allowanceDraft)
            .frame(width: 100)
            .disabled(candidate.quotaMetricID == nil)
            .onChange(of: allowanceDraft) { _, new in updateAllowance(new) }
        }
        .font(.callout)
        if metrics.isEmpty {
          Text("Refresh this account to make its quota windows available.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let allowanceError {
          Text(allowanceError).font(.caption).foregroundStyle(.red)
        }
        if let allocation = subscriptionAllocation {
          Text("Automatic cost for 100% of this window: \(allocation.allowanceCost.formatted(.currency(code: reportCurrency))). \(allocation.explanation)")
            .font(.caption).foregroundStyle(.secondary)
        } else if let price = subscription, candidate.quotaMetricID != nil {
          Text(price.currency != reportCurrency
            ? "Account currency \(price.currency) differs from report currency \(reportCurrency). Change the report currency or enter an override; currencies are not converted automatically."
            : "No comparable window duration is reported. Enter a manual allocation to estimate cost for this window.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("Leave the override blank to use the account price. Estimates allocate the fee across all available quota; they are not extra provider charges.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear {
      allowanceDraft = candidate.allowanceCost.map { String($0) } ?? ""
      if candidate.quotaMetricID == nil, subscription != nil {
        candidate.quotaMetricID = BenchmarkPriceAllocation.defaultMetricID(in: metrics, provider: provider)
      }
    }
    .onChange(of: candidate.quotaMetricID) { _, new in
      if new == nil {
        candidate.allowanceCost = nil
        allowanceDraft = ""
        allowanceError = nil
        reportValidity()
      }
    }
    .onChange(of: subscription) { _, _ in
      if candidate.quotaMetricID == nil, subscription != nil {
        candidate.quotaMetricID = BenchmarkPriceAllocation.defaultMetricID(in: metrics, provider: provider)
      }
    }
  }

  private func updateAllowance(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      candidate.allowanceCost = nil
      allowanceError = nil
    } else if let amount = Double(trimmed), amount.isFinite, amount >= 0 {
      candidate.allowanceCost = amount
      allowanceError = nil
    } else {
      allowanceError = "Enter a nonnegative finite amount, or leave it blank."
    }
    reportValidity()
  }

  private func reportValidity() {
    onValidity(commandValid && allowanceError == nil)
  }
}

private struct BenchmarkCommandEditor: View {
  @Binding var command: BenchmarkCommand
  @ObservedObject var benchmark: BenchmarkViewModel
  let repositoryPath: String
  let judge: Bool
  let onValidity: (Bool) -> Void
  @State private var argumentDraft = ""
  @State private var argumentError: String?
  @State private var nativeValid = true

  private var isNative: Bool { command.outputFormat == .piJSON || command.outputFormat == .opencodeJSON }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("Absolute path to CLI executable", text: $command.executable)
          .font(.system(.callout, design: .monospaced))
        Button("Choose…") { chooseExecutable() }
      }
      if isNative {
        BenchmarkHarnessPicker(command: $command, benchmark: benchmark,
                               repositoryPath: repositoryPath, judge: judge) { valid in
          nativeValid = valid
          reportValidity()
        }
      }
      DisclosureGroup("Advanced command") {
        TextField("Arguments as a JSON array", text: $argumentDraft, axis: .vertical)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(2...5)
          .onChange(of: argumentDraft) { _, new in updateArguments(new) }
        if let argumentError {
          Text(argumentError).font(.caption).foregroundStyle(.red)
        }
        HStack {
          Picker("Output", selection: $command.outputFormat) {
            Text("Plain text").tag(BenchmarkOutputFormat.text)
            Text("Codex JSON").tag(BenchmarkOutputFormat.codexJSON)
            Text("Claude JSON").tag(BenchmarkOutputFormat.claudeJSON)
            Text("Pi JSON").tag(BenchmarkOutputFormat.piJSON)
            Text("OpenCode JSON").tag(BenchmarkOutputFormat.opencodeJSON)
          }
          Spacer()
        }
        Text("Use {prompt} in an argument, or the prompt is sent on standard input. Arguments are passed directly to the executable. Keep credentials in the CLI's login store.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear { argumentDraft = encodedArguments(command.arguments) }
    .onChange(of: command.arguments) { _, new in
      if decodedArguments(argumentDraft) != new {
        argumentDraft = encodedArguments(new)
        argumentError = nil
        reportValidity()
      }
    }
    .onChange(of: command.outputFormat) { _, _ in
      nativeValid = true
      reportValidity()
    }
  }

  private func updateArguments(_ text: String) {
    guard let arguments = decodedArguments(text) else {
      argumentError = "Enter a JSON array of strings, for example [\"exec\", \"{prompt}\"]."
      reportValidity()
      return
    }
    command.arguments = arguments
    argumentError = nil
    reportValidity()
  }

  private func reportValidity() { onValidity(argumentError == nil && nativeValid) }

  private func decodedArguments(_ text: String) -> [String]? {
    try? JSONDecoder().decode([String].self, from: Data(text.utf8))
  }

  private func encodedArguments(_ arguments: [String]) -> String {
    guard let data = try? JSONEncoder().encode(arguments), let text = String(data: data, encoding: .utf8) else { return "[]" }
    return text
  }

  private func chooseExecutable() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose executable"
    if panel.runModal() == .OK, let url = panel.url { command.executable = url.path }
  }
}

private struct BenchmarkHarnessPicker: View {
  @Binding var command: BenchmarkCommand
  @ObservedObject var benchmark: BenchmarkViewModel
  let repositoryPath: String
  let judge: Bool
  let onValidity: (Bool) -> Void
  @State private var models: [BenchmarkHarnessModel] = []
  @State private var selectedProvider = ""
  @State private var selectedModel = ""
  @State private var loadPlugins = false
  @State private var isLoading = false
  @State private var requiresSelection = false
  @State private var errorMessage: String?
  @State private var lookup: Task<Void, Never>?
  @State private var requestID = UUID()

  private var harness: BenchmarkHarness {
    command.outputFormat == .piJSON ? .pi : .opencode
  }

  private var providers: [String] { Array(Set(models.map(\.provider))).sorted() }

  private var commandSelection: (provider: String?, model: String?) {
    func argument(_ names: [String]) -> String? {
      guard let index = command.arguments.lastIndex(where: { names.contains($0) }),
            command.arguments.indices.contains(index + 1) else { return nil }
      return command.arguments[index + 1]
    }
    if harness == .pi { return (argument(["--provider"]), argument(["--model"])) }
    guard let selected = argument(["--model", "-m"]) else { return (nil, nil) }
    let parts = selected.split(separator: "/", maxSplits: 1).map(String.init)
    return parts.count == 2 ? (parts[0], parts[1]) : (nil, selected)
  }

  private var modelSummary: String {
    guard let model = commandSelection.model else { return "Model: CLI-configured default" }
    if let provider = commandSelection.provider { return "Model: \(provider)/\(model)" }
    return "Model: \(model) · Provider: CLI-configured default"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(modelSummary)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(models.isEmpty ? "Discover models" : "Refresh models") { discover() }
          .disabled(isLoading || command.executable.isEmpty)
        if isLoading {
          ProgressView().controlSize(.small)
          Text("Reading \(harness.displayName) configuration…")
            .font(.caption).foregroundStyle(.secondary)
          Button("Cancel") { invalidate() }
        } else if !models.isEmpty {
          Text("\(models.count) models · \(providers.count) providers")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle("Load configured extensions/plugins", isOn: Binding(
        get: { loadPlugins }, set: updatePlugins))
        .toggleStyle(.checkbox)
        .font(.caption)
      if !models.isEmpty {
        Picker("Provider", selection: Binding(get: { selectedProvider }, set: selectProvider)) {
          Text("Choose provider").tag("")
          ForEach(providers, id: \.self) { Text($0).tag($0) }
        }
        if !selectedProvider.isEmpty {
          Picker("Model", selection: Binding(get: { selectedModel }, set: selectModel)) {
            Text("Choose model").tag("")
            ForEach(models.filter { $0.provider == selectedProvider }) { model in
              Text(model.displayName == model.modelID ? model.modelID : "\(model.displayName) (\(model.modelID))")
                .tag(model.id)
            }
          }
        }
      }
      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red)
      }
      if requiresSelection {
        Text("Discover and select a model, or use the CLI's configured default.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Use configured default") { useDefault() }
        .font(.caption)
      Text("Discovery reads configured providers and models without sending a task. Availability does not verify access or remaining quota. Select a model for a reproducible comparison; the current command is used until you select one.")
        .font(.caption).foregroundStyle(.secondary)
      Text("The same extensions/plugins setting is used for discovery and execution. Repository settings come from committed HEAD.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { loadPlugins = configuredPlugins; reportValidity() }
    .onDisappear { lookup?.cancel() }
    .onChange(of: command.executable) { _, _ in invalidate(requireSelection: true) }
    .onChange(of: command.outputFormat) { _, _ in invalidate(); loadPlugins = configuredPlugins }
    .onChange(of: repositoryPath) { _, _ in invalidate(requireSelection: true) }
    .onChange(of: command.arguments) { _, _ in synchronizeSelection() }
  }

  private var configuredPlugins: Bool {
    !command.arguments.contains(harness == .pi ? "--no-extensions" : "--pure")
  }

  private func updatePlugins(_ enabled: Bool) {
    loadPlugins = enabled
    invalidate(requireSelection: true)
    let flag = harness == .pi ? "--no-extensions" : "--pure"
    command.arguments.removeAll { $0 == flag }
    if !enabled { command.arguments.append(flag) }
  }

  private func selectProvider(_ provider: String) {
    selectedProvider = provider
    selectedModel = ""
    requiresSelection = true
    reportValidity()
  }

  private func selectModel(_ id: String) {
    selectedModel = id
    guard let model = models.first(where: { $0.id == id }) else {
      requiresSelection = true
      reportValidity()
      return
    }
    command = model.command(executable: command.executable, judge: judge)
    requiresSelection = false
    reportValidity()
  }

  private func discover() {
    lookup?.cancel()
    requiresSelection = requiresSelection || !selectedModel.isEmpty
    models = []
    selectedProvider = ""
    selectedModel = ""
    let id = UUID()
    requestID = id
    let kind = harness
    let executable = command.executable
    let repository = repositoryPath
    let plugins: BenchmarkHarnessPluginPolicy = loadPlugins ? .configured : .disabled
    isLoading = true
    errorMessage = nil
    reportValidity()
    lookup = Task { @MainActor in
      do {
        let found = try await benchmark.discoverHarnessModels(harness: kind, executable: executable,
          plugins: plugins, repositoryPath: repository)
        guard !Task.isCancelled, requestID == id, harness == kind,
              command.executable == executable, repositoryPath == repository else { return }
        models = found
        isLoading = false
        lookup = nil
        if found.isEmpty {
          errorMessage = "No configured models were returned. Check the CLI login, provider settings, and extensions/plugins option."
        }
        synchronizeSelection()
        reportValidity()
      } catch {
        guard !Task.isCancelled, requestID == id else { return }
        isLoading = false
        lookup = nil
        errorMessage = error.localizedDescription
        reportValidity()
      }
    }
  }

  private func invalidate(requireSelection: Bool = false) {
    lookup?.cancel()
    lookup = nil
    requestID = UUID()
    isLoading = false
    models = []
    selectedProvider = ""
    selectedModel = ""
    requiresSelection = requireSelection
    errorMessage = nil
    reportValidity()
  }

  private func synchronizeSelection() {
    guard !models.isEmpty else { reportValidity(); return }
    let selection = commandSelection
    if let model = models.first(where: { $0.provider == selection.provider && $0.modelID == selection.model }) {
      selectedProvider = model.provider
      selectedModel = model.id
      requiresSelection = false
    } else {
      selectedProvider = ""
      selectedModel = ""
      if selection.model != nil { requiresSelection = true }
    }
    reportValidity()
  }

  private func useDefault() {
    let executable = command.executable
    invalidate()
    command = (harness == .pi ? BenchmarkCLIPreset.pi : .opencode).command(judge: judge)
    command.executable = executable
    if loadPlugins { command.arguments.removeAll { $0 == "--pure" || $0 == "--no-extensions" } }
    reportValidity()
  }

  private func reportValidity() { onValidity(!isLoading && !requiresSelection) }
}

private enum BenchmarkCLIPreset: String, CaseIterable, Identifiable {
  case pi, opencode, codex, claude, junie, custom
  var id: String { rawValue }

  var title: String {
    switch self {
    case .pi: return "Pi"
    case .opencode: return "OpenCode"
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .junie: return "Junie Lite"
    case .custom: return "Custom CLI"
    }
  }

  @MainActor
  func command(judge: Bool) -> BenchmarkCommand {
    let command = baseCommand(judge: judge)
    return judge ? BenchmarkJudgeInspection.enablingInspection(in: command) ?? command : command
  }

  @MainActor
  private func baseCommand(judge: Bool) -> BenchmarkCommand {
    switch self {
    case .pi:
      return BenchmarkCommand(executable: BenchmarkViewModel.defaultExecutable(named: "pi"),
        arguments: ["--mode", "json", "--print", "--no-session", "--offline", "--no-extensions"] +
          (judge ? ["--no-tools", "--no-skills", "--no-context-files", "--no-prompt-templates"] : []), outputFormat: .piJSON)
    case .opencode:
      return BenchmarkCommand(executable: BenchmarkViewModel.defaultExecutable(named: "opencode"),
        arguments: ["run", "--format", "json", "--pure"] +
          (judge ? ["--agent", BenchmarkHarness.makeJudgeAgentName()] : []), outputFormat: .opencodeJSON)
    case .codex:
      return BenchmarkCommand(
        executable: BenchmarkViewModel.defaultExecutable(named: "codex"),
        arguments: ["exec", "--json", "--sandbox", judge ? "read-only" : "workspace-write", "-"],
        outputFormat: .codexJSON
      )
    case .claude:
      return BenchmarkCommand(
        executable: BenchmarkViewModel.defaultExecutable(named: "claude"),
        arguments: judge ? ["-p", "--output-format", "json", "--tools", ""] : ["-p", "--output-format", "json", "--permission-mode", "acceptEdits"], outputFormat: .claudeJSON
      )
    case .junie:
      return BenchmarkCommand(
        executable: BenchmarkViewModel.defaultExecutable(named: "junie"),
        arguments: ["--skip-update-check", "--model", "junie-lite", "--task", "{prompt}"]
      )
    case .custom:
      return BenchmarkCommand(executable: "", arguments: ["{prompt}"])
    }
  }
}
