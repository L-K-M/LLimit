import Foundation
import QuotaCore
import LLimitdCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

func writeStandardError(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

func failUsage(_ error: Error) -> Never {
  writeStandardError("llimit: \(error.localizedDescription)")
  exit(QuotaCheckStatus.usage.rawValue)
}

final class StatusWarnings {
  private var written: Set<String> = []
  func warn(_ line: String) {
    guard written.insert(line).inserted else { return }
    writeStandardError(line)
  }
}

func loadDisplaySnapshot(warn: (String) -> Void = writeStandardError) -> QuotaSnapshot? {
  do { return try StatusReader.loadSnapshot(paths: LinuxPaths()) }
  catch {
    warn("llimit: could not read the snapshot")
    return nil
  }
}

func runStatus(_ args: [String]) async {
  let options: StatusOptions
  do { options = try StatusOptions.parse(args) }
  catch { failUsage(error) }
  let warnings = StatusWarnings()
  var frame = WatchFrame()
  while !Task.isCancelled {
    let rendering: StatusCommand.Rendering
    do { rendering = try StatusCommand.render(options, snapshot: loadDisplaySnapshot(warn: warnings.warn), now: Date()) }
    catch { failUsage(error) }
    for target in rendering.unmatchedTargets { warnings.warn("llimit: no data for \"\(target)\"") }
    let output: WatchFrame.Output = options.watchInterval != nil && options.output != .json && isatty(STDOUT_FILENO) == 1 ? .terminal : .stream
    FileHandle.standardOutput.write(Data(frame.render(rendering.text, output: output).utf8))
    guard let interval = options.watchInterval else { return }
    do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
    catch { return }
  }
}

func runCheck(_ args: [String]) {
  let options: CheckOptions
  do { options = try CheckOptions.parse(args) }
  catch { failUsage(error) }
  let verdict = QuotaCheck.check(options, snapshot: loadDisplaySnapshot(), now: Date())
  if verdict.status == .usage { writeStandardError("llimit: \(verdict.message)") }
  else { print(verdict.message) }
  exit(verdict.status.rawValue)
}

func runPick(_ args: [String]) {
  let options: PickOptions
  do { options = try PickOptions.parse(args) }
  catch { failUsage(error) }
  let snapshot = loadDisplaySnapshot()
  let now = Date()
  let verdict = QuotaCheck.pick(options, snapshot: snapshot, now: now)
  guard verdict.status == .ok, let candidate = verdict.candidate, let snapshot else {
    writeStandardError("llimit: \(verdict.message)")
    exit(verdict.status.rawValue)
  }
  print(StatusTemplate.render(options.template, accountKey: candidate.accountKey, in: snapshot, kind: options.criteria.kind, now: now))
}

func runResets(_ args: [String]) {
  let options: ResetsOptions
  do { options = try ResetsOptions.parse(args) }
  catch { failUsage(error) }
  let snapshot = loadDisplaySnapshot()
  let now = Date()
  switch options.output {
  case .human: print(StatusRenderer.resetsHumanReadable(snapshot: snapshot, now: now, windowDays: options.days))
  case .json: print(StatusRenderer.resetsJSON(snapshot: snapshot, now: now, windowDays: options.days))
  }
}
