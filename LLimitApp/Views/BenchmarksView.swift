import AppKit
import SwiftUI
import QuotaCore

struct BenchmarksView: View {
  @ObservedObject private var model: AppModel
  @ObservedObject private var benchmark: BenchmarkViewModel
  @State private var accountsConfirmed = false
  @State private var invalidEditors: Set<UUID> = []

  init(model: AppModel) {
    self.model = model
    self.benchmark = model.benchmarks
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        if let error = benchmark.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        if benchmark.isRunning {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(benchmark.progress).font(.callout)
            Spacer()
            Button("Cancel", role: .cancel) { benchmark.cancel() }
          }
          .padding(12)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        setup
          .disabled(benchmark.isRunning)
        if let report = benchmark.report {
          reportSection(report)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
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
              }
            }
          } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
          }
          .disabled(benchmark.isRunning)
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
          LabeledContent("Quota reporting delay (seconds)") {
            TextField("0", value: $benchmark.plan.settleSeconds, format: .number)
              .frame(width: 85)
          }
          TextField("Optional acceptance command, for example swift test", text: Binding(
            get: { benchmark.plan.acceptanceCommand ?? "" },
            set: { benchmark.plan.acceptanceCommand = $0.isEmpty ? nil : $0 }
          ))
          .font(.system(.body, design: .monospaced))
          Text("The acceptance command runs inside each attempt's workspace. An unsuccessful exit rejects that result.")
            .font(.caption).foregroundStyle(.secondary)
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
              accounts: model.providerAccounts,
              usages: model.snapshot?.providers ?? [],
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
              BenchmarkCommandEditor(command: $judge.command) {
                setValidity(judge.id, valid: $0)
              }
            }
            if judge.id != benchmark.plan.judges.last?.id { Divider() }
          }
          Text("Choose the models through each CLI's arguments. Judge time is reported separately from agent execution.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
      } label: {
        Label("Judges", systemImage: "checkmark.bubble")
      }

      Toggle("The CLI logins match the selected accounts, and these accounts are idle elsewhere.", isOn: $accountsConfirmed)
        .toggleStyle(.checkbox)
        .font(.callout)
      HStack {
        Button {
          accountsConfirmed = false
          benchmark.start()
        } label: {
          Label("Run benchmark", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!accountsConfirmed || !invalidEditors.isEmpty || benchmark.plan.candidates.isEmpty)
        Text("Runs agents and judges using their configured subscriptions or API accounts.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .textFieldStyle(.roundedBorder)
  }

  private func reportSection(_ report: BenchmarkReport) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Divider()
      HStack {
        Text("Results").font(.title3.weight(.semibold))
        Spacer()
        Button("Export JSON…") { benchmark.exportReport() }
        Button("Show files") { benchmark.revealArtifacts() }
      }
      Text("\(report.startedAt.formatted(date: .abbreviated, time: .shortened)) · commit \(report.baselineCommit.prefix(12))")
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      comparison(report)
      Text("Costs are allocated estimates from the price you assigned to a quota window, rather than additional charges. Unknown costs remain unavailable. Failed attempts are included in cost per accepted result.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Judge time: \(duration(report.judgeDurationSeconds)). Acceptance requires both judges to accept the result and any acceptance command to pass.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.orange)
      }
      ForEach(report.runs, id: \.id) { run in
        runCard(run, report: report)
      }
    }
  }

  private func comparison(_ report: BenchmarkReport) -> some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
        GridRow {
          Text("Agent"); Text("Accepted"); Text("Median time"); Text("Quality / 10"); Text("Allocated cost"); Text("Cost / accepted")
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Divider().gridCellUnsizedAxes(.horizontal)
        ForEach(report.summaries, id: \.candidateID) { summary in
          GridRow {
            Text(summary.name).fontWeight(.medium)
            Text("\(summary.acceptedCount) / \(summary.attempts)")
            Text(duration(summary.medianDurationSeconds))
            Text(summary.meanQualityScore.map { String(format: "%.1f", $0) } ?? "Unavailable")
            Text(money(summary.estimatedTotalCost, currency: report.plan.currency))
            Text(money(summary.estimatedCostPerAcceptedTask, currency: report.plan.currency))
          }
        }
      }
      .font(.callout).monospacedDigit()
      .padding(14)
    }
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private func runCard(_ run: BenchmarkRun, report: BenchmarkReport) -> some View {
    let candidate = report.plan.candidates.first { $0.id == run.candidateID }
    return GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("\(candidate?.name ?? "Agent") · attempt \(run.repetition)")
            .font(.headline)
          Spacer()
          Text(run.outcome.rawValue).foregroundStyle(.secondary)
          Text(duration(run.durationSeconds)).monospacedDigit()
        }
        HStack(spacing: 14) {
          Label(acceptanceLabel(run), systemImage: run.isAccepted == true ? "checkmark.circle" : "circle.dashed")
          if let passed = run.acceptancePassed {
            Text(passed ? "Acceptance command passed" : "Acceptance command failed")
          }
        }
        .font(.caption).foregroundStyle(.secondary)
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
        ForEach(Array(run.evaluations.enumerated()), id: \.offset) { _, evaluation in
          VStack(alignment: .leading, spacing: 3) {
            let judgeName = report.plan.judges.first { $0.id == evaluation.judgeID }?.name ?? "Judge"
            HStack {
              Text(judgeName).fontWeight(.medium)
              if let score = evaluation.score { Text(String(format: "%.1f / 10", score)) }
              if let accepted = evaluation.accepted { Text(accepted ? "Accepted" : "Rejected") }
            }
            if let error = evaluation.error { Text(error).foregroundStyle(.red) }
            if !evaluation.explanation.isEmpty { Text(evaluation.explanation).foregroundStyle(.secondary) }
          }
          .font(.callout).textSelection(.enabled)
        }
        if !run.output.isEmpty {
          DisclosureGroup("Agent output") { evidence(run.output) }
        }
        if !run.patch.isEmpty {
          DisclosureGroup("Changes") { evidence(run.patch) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
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

  private func acceptanceLabel(_ run: BenchmarkRun) -> String {
    switch run.isAccepted {
    case true?: return "Accepted"
    case false?: return "Rejected"
    case nil: return "Acceptance unresolved"
    }
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
  let accounts: [ProviderAccount]
  let usages: [ProviderUsage]
  let onValidity: (Bool) -> Void
  let onRemove: () -> Void
  @State private var commandValid = true
  @State private var allowanceDraft = ""
  @State private var allowanceError: String?

  private var metrics: [UsageMetric] {
    usages.first { $0.accountID == candidate.accountID }?.metrics ?? []
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
      BenchmarkCommandEditor(command: $candidate.command) { valid in
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
        candidate.quotaMetricID = nil
        candidate.allowanceCost = nil
        allowanceDraft = ""
        allowanceError = nil
        reportValidity()
      }
      if candidate.accountID != nil {
        Picker("Cost allocation window", selection: $candidate.quotaMetricID) {
          Text("No cost estimate").tag(String?.none)
          ForEach(metrics) { metric in
            Text(metric.label).tag(Optional(metric.id))
          }
        }
        LabeledContent("Allocated cost of 100% of this window") {
          TextField("Optional", text: $allowanceDraft)
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
        Text("For example, enter your chosen weekly share of the subscription price for a weekly limit. This is an allocation assumption.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear {
      allowanceDraft = candidate.allowanceCost.map { String($0) } ?? ""
    }
    .onChange(of: candidate.quotaMetricID) { _, new in
      if new == nil {
        candidate.allowanceCost = nil
        allowanceDraft = ""
        allowanceError = nil
        reportValidity()
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
  let onValidity: (Bool) -> Void
  @State private var argumentDraft = ""
  @State private var argumentError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("Absolute path to CLI executable", text: $command.executable)
          .font(.system(.callout, design: .monospaced))
        Button("Choose…") { chooseExecutable() }
      }
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
        }
        Spacer()
      }
      Text("Use {prompt} in an argument, or the prompt is sent on standard input. Arguments are passed directly to the executable. Keep credentials in the CLI's login store.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { argumentDraft = encodedArguments(command.arguments) }
    .onChange(of: command.arguments) { _, new in
      if decodedArguments(argumentDraft) != new {
        argumentDraft = encodedArguments(new)
        argumentError = nil
        onValidity(true)
      }
    }
  }

  private func updateArguments(_ text: String) {
    guard let arguments = decodedArguments(text) else {
      argumentError = "Enter a JSON array of strings, for example [\"exec\", \"{prompt}\"]."
      onValidity(false)
      return
    }
    command.arguments = arguments
    argumentError = nil
    onValidity(true)
  }

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

private enum BenchmarkCLIPreset: String, CaseIterable, Identifiable {
  case codex, claude, junie, custom
  var id: String { rawValue }

  var title: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .junie: return "Junie Lite"
    case .custom: return "Custom CLI"
    }
  }

  @MainActor
  func command(judge: Bool) -> BenchmarkCommand {
    switch self {
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
