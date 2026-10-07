import Foundation
import QuotaCore
import LLimitdCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// `llimit status`, `check` and `pick`: display and scripting commands that read
// only the credential-free snapshot. Bars and prompts poll them constantly, so
// they never open the settings file.

/// The snapshot as last written by a refresh. An unreadable file is reported
/// through `warn` and rendered as "no data", as `llimit status` always has.
func loadDisplaySnapshot(warn: (String) -> Void = writeStandardError) -> QuotaSnapshot? {
  do {
    return try SnapshotStore(fileURL: LinuxPaths().snapshotFileURL).load()
  } catch {
    warn("llimit: could not read the snapshot: \(error.localizedDescription)")
    return nil
  }
}

func writeStandardError(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Writes each distinct diagnostic once, so `--watch` does not repeat the same
/// warning on stderr every interval.
final class StatusWarnings {
  private var written: Set<String> = []

  func warn(_ line: String) {
    guard written.insert(line).inserted else { return }
    writeStandardError(line)
  }
}

/// One `llimit status` render. Flushed so a `--watch` consumer reading a pipe
/// gets each render as it happens instead of when the stdio buffer fills.
func printStatus(_ options: StatusOptions, warnings: StatusWarnings) {
  let rendering: StatusCommand.Rendering
  do {
    rendering = try StatusCommand.render(options, snapshot: loadDisplaySnapshot(warn: warnings.warn), now: Date())
  } catch {
    fail(error.localizedDescription)
  }

  for target in rendering.unmatchedTargets {
    // A target may be a provider id, so the warning does not call it an account.
    warnings.warn("llimit: no data for \"\(target)\"")
  }
  print(rendering.text)
  fflush(stdout)
}

/// `check` and `pick` exit with `QuotaCheckStatus` codes, so a usage error must
/// not reuse 1 ("below minimum") the way `fail` does.
func failUsage(_ error: Error) -> Never {
  writeStandardError("llimit: \(error.localizedDescription)")
  exit(QuotaCheckStatus.usage.rawValue)
}

func runCheck(_ args: [String]) {
  let options: CheckOptions
  do {
    options = try CheckOptions.parse(args)
  } catch {
    failUsage(error)
  }

  let verdict = QuotaCheck.check(options, snapshot: loadDisplaySnapshot(), now: Date())
  if verdict.status == .usage {
    writeStandardError("llimit: \(verdict.message)")
  } else {
    print(verdict.message)
  }
  exit(verdict.status.rawValue)
}

/// Prints only the chosen account on stdout, so `$(llimit pick)` is empty
/// whenever nothing qualifies; the reason goes to stderr.
func runPick(_ args: [String]) {
  let options: PickOptions
  do {
    options = try PickOptions.parse(args)
  } catch {
    failUsage(error)
  }

  let now = Date()
  let snapshot = loadDisplaySnapshot()
  let verdict = QuotaCheck.pick(options, snapshot: snapshot, now: now)
  guard verdict.status == .ok, let chosen = verdict.candidate, let snapshot else {
    writeStandardError("llimit: \(verdict.message)")
    exit(verdict.status.rawValue)
  }

  print(StatusTemplate.render(options.template, accountID: chosen.accountID, in: snapshot, kind: options.criteria.kind, now: now))
}
