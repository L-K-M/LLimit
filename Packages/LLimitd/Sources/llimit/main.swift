import Foundation
import QuotaCore
import LLimitdCore
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// llimit — headless LLimit for Linux: account management CLI plus the refresh daemon.
// The macOS app's Settings → Accounts surface maps to `llimit accounts …`; the menu
// bar snapshot contract maps to `llimit status --json`.

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("llimit: \(message)\n".utf8))
  exit(1)
}

func printUsage() {
  print(
    """
    llimit — LLM subscription quota tracking for Linux

    Usage:
      llimit accounts list
      llimit accounts add --provider <id> [--name <name>] [--set key=value …]
      llimit accounts import [--id <stable-id> | --all]
      llimit accounts enable <account-id>
      llimit accounts disable <account-id>
      llimit accounts remove <account-id>
      llimit accounts update <account-id> [--name <name>] [--set key[=value] …]
      llimit accounts rename <account-id> <name>
      llimit accounts reimport <account-id> [--from <stable-id>]
      llimit accounts import [--id <stable-id> | --all] --new
      llimit refresh
      llimit status [--json]
      llimit daemon
      llimit paths

    Providers: \(QuotaProvider.allCases.map(\.rawValue).joined(separator: ", "))
    Account IDs may be shortened to any unique prefix.
    """
  )
}

/// Loads settings for a command. An unreadable settings file stops every command
/// that works with the settings. `status` only renders the saved snapshot, so it
/// carries on and bars keep showing the last-known usage; the problem goes to
/// stderr.
func makeDaemon() -> QuotaDaemon {
  let daemon = QuotaDaemon(paths: LinuxPaths())
  daemon.loadConfiguration()
  guard let settingsError = daemon.settingsLoadError else { return daemon }

  if arguments.first == "status" {
    FileHandle.standardError.write(Data("llimit: warning: \(settingsError.localizedDescription)\n".utf8))
    return daemon
  }
  fail(settingsError.localizedDescription)
}

/// Prints the note shared by `add` and `update` when required fields are empty.
func noteMissingCredentials(of account: ProviderAccount) {
  let missing = account.missingCredentialLabels
  if !missing.isEmpty {
    print("Note: still missing \(missing.joined(separator: ", ")); the account will be skipped until complete.")
  }
}

// MARK: - accounts

func runAccounts(_ args: [String]) {
  guard let subcommand = args.first else {
    printUsage()
    exit(1)
  }

  switch subcommand {
  case "list":
    accountsList()
  case "add":
    accountsAdd(Array(args.dropFirst()))
  case "import":
    accountsImport(Array(args.dropFirst()))
  case "enable", "disable":
    guard let fragment = args.dropFirst().first else {
      fail("accounts \(subcommand) needs an account ID")
    }
    accountsSetEnabled(fragment, enabled: subcommand == "enable")
  case "remove":
    guard let fragment = args.dropFirst().first else {
      fail("accounts remove needs an account ID")
    }
    accountsRemove(fragment)
  case "update":
    accountsUpdate(Array(args.dropFirst()))
  case "rename":
    let rest = args.dropFirst()
    guard let fragment = rest.first, rest.count > 1 else {
      fail("accounts rename needs an account ID and a name")
    }
    accountsUpdate([fragment, "--name", rest.dropFirst().joined(separator: " ")])
  case "reimport":
    accountsReimport(Array(args.dropFirst()))
  default:
    fail("unknown accounts subcommand: \(subcommand)")
  }
}

func accountsList() {
  let daemon = makeDaemon()

  if daemon.settings.accounts.isEmpty {
    print("No accounts. Add one with `llimit accounts add --provider <id>` or import a")
    print("local tool login with `llimit accounts import`.")
    return
  }

  for account in daemon.settings.accounts {
    let state = account.isEnabled ? "enabled" : "disabled"
    let missing = account.missingCredentialLabels
    let readiness = missing.isEmpty ? "ready" : "missing: \(missing.joined(separator: ", "))"
    print("\(account.id)")
    print("    \(account.resolvedDisplayName) [\(account.provider.rawValue)] — \(state), \(readiness)")
  }
}

func accountsAdd(_ args: [String]) {
  var providerID: String?
  var name: String?
  var presetCredentials: [String: String] = [:]

  var index = 0
  while index < args.count {
    let arg = args[index]
    func takeValue() -> String {
      guard index + 1 < args.count else { fail("\(arg) needs a value") }
      index += 1
      return args[index]
    }
    switch arg {
    case "--provider":
      providerID = takeValue()
    case "--name":
      name = takeValue()
    case "--set":
      let pair = takeValue()
      guard let equals = pair.firstIndex(of: "=") else {
        fail("--set expects key=value (got \"\(pair)\")")
      }
      presetCredentials[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    default:
      fail("unknown option: \(arg)")
    }
    index += 1
  }

  guard
    let providerID,
    let provider = QuotaProvider(rawValue: providerID)
  else {
    fail("accounts add needs --provider <id> where id is one of: \(QuotaProvider.allCases.map(\.rawValue).joined(separator: ", "))")
  }

  // Load first, so an unreadable settings file stops the command before any
  // secret is typed.
  let daemon = makeDaemon()

  // Fill any fields not given via --set by prompting. Secrets are read with terminal
  // echo disabled; when stdin is not a TTY (scripts), required fields must come from
  // --set instead.
  var credentials = presetCredentials
  let interactive = isatty(STDIN_FILENO) == 1
  for field in provider.credentialFields where credentials[field.key] == nil {
    if !interactive {
      if field.isRequired {
        fail("missing required field \"\(field.key)\" — pass it as --set \(field.key)=… (stdin is not a terminal)")
      }
      continue
    }

    if let help = field.help {
      print("  \(help)")
    }
    let optional = field.isRequired ? "" : " (optional, Enter to skip)"
    let value = readField(prompt: "\(field.label)\(optional): ", secret: field.isSecret)
    credentials[field.key] = value
  }

  // Lock from re-load through save so a concurrent daemon token-refresh save
  // cannot silently drop the new account (and vice versa).
  let account: ProviderAccount
  do {
    account = try daemon.editingSettings { transaction in
      try transaction.addAccount(provider: provider, displayName: name, credentials: credentials)
    }
  } catch {
    fail(error.localizedDescription)
  }
  print("Added \(account.resolvedDisplayName) [\(account.provider.rawValue)] — id \(account.id)")
  noteMissingCredentials(of: account)
}

func accountsImport(_ args: [String]) {
  var wantedID: String?
  var importAll = false
  var addSeparately = false

  var index = 0
  while index < args.count {
    switch args[index] {
    case "--id":
      guard index + 1 < args.count else { fail("--id needs a value") }
      index += 1
      wantedID = args[index]
    case "--all":
      importAll = true
    case "--new":
      addSeparately = true
    default:
      fail("unknown option: \(args[index])")
    }
    index += 1
  }

  let daemon = makeDaemon()
  daemon.scanForDetectedCredentials()

  if daemon.detectedCredentials.isEmpty {
    print("No local tool logins found.")
    for line in daemon.discoveryDiagnostics {
      print("  \(line)")
    }
    return
  }

  /// What to do with one detected login. Decided before taking the settings lock,
  /// so a prompt never holds up the daemon.
  enum ImportDecision {
    case skip
    case add
    case update(accountID: String)
  }
  /// Set when a login was left alone because only the user can tell whether it
  /// renews an existing account; the command then exits non-zero.
  var undecided = false

  func alreadyImported(_ detected: DiscoveredCredential) {
    print("\(detected.provider.displayName) from \(detected.sourceLabel): already imported, skipping.")
  }

  /// A renewed token shares nothing with the expired one, so it can't be matched
  /// automatically: ask whether it updates an existing account or is a new one.
  func chooseUpdate(for detected: DiscoveredCredential, among accountIDs: [String]) -> ImportDecision {
    let accounts = accountIDs.compactMap { daemon.settings.account(withID: $0) }
    let login = "\(detected.provider.displayName) from \(detected.sourceLabel)"

    guard isatty(STDIN_FILENO) == 1 else {
      undecided = true
      let names = accounts.map { "\($0.resolvedDisplayName) (\($0.id))" }.joined(separator: ", ")
      FileHandle.standardError.write(Data("""
        llimit: \(login) is a different login than \(names); not imported.
          To update an account with it: llimit accounts reimport <account-id> --from \(detected.stableID)
          To add it as a separate account: llimit accounts import --id \(detected.stableID) --new

        """.utf8))
      return .skip
    }

    print("\n\(login) is a different login than:")
    for (offset, account) in accounts.enumerated() {
      print("  \(offset + 1). \(account.resolvedDisplayName) [\(account.provider.rawValue)] — id \(account.id)")
    }
    let range = accounts.count == 1 ? "1" : "1-\(accounts.count)"
    // Ask again on a typo instead of exiting, which would drop the answers
    // already given for other logins.
    while true {
      print("Update account [\(range)] with it, add a [n]ew account, or Enter to skip: ", terminator: "")
      guard let line = readLine() else {
        // End of input is not an answer: leave the login alone and say so.
        undecided = true
        print("\nNo answer; \(login) not imported.")
        return .skip
      }

      let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if answer.isEmpty {
        print("Skipped.")
        return .skip
      }
      if answer == "n" {
        return .add
      }
      if let choice = Int(answer), accounts.indices.contains(choice - 1) {
        return .update(accountID: accounts[choice - 1].id)
      }
      print("Invalid selection: \(answer). Choose \(range), n, or press Enter to skip.")
    }
  }

  func decide(_ detected: DiscoveredCredential) -> ImportDecision {
    switch daemon.importMatch(for: detected, among: daemon.detectedCredentials) {
    case .alreadyImported:
      alreadyImported(detected)
      return .skip
    case .newAccount:
      return .add
    case .updateCandidates(let accountIDs):
      return addSeparately ? .add : chooseUpdate(for: detected, among: accountIDs)
    }
  }

  func apply(_ decision: ImportDecision, to detected: DiscoveredCredential, in transaction: SettingsTransaction) throws {
    switch decision {
    case .skip:
      return
    case .add:
      // Checked again under the lock: another process may have imported it.
      if daemon.isDetectedCredentialImported(detected) {
        alreadyImported(detected)
        return
      }
      let account = try transaction.importAccount(from: detected)
      print("Imported \(account.resolvedDisplayName) [\(account.provider.rawValue)] from \(detected.sourceLabel) — id \(account.id)")
    case .update(let accountID):
      let account = try transaction.updateAccount(accountID, credentials: .replacing(with: detected.credentials))
      print("Updated \(account.resolvedDisplayName) [\(account.provider.rawValue)] from \(detected.sourceLabel) — id \(account.id)")
    }
  }

  /// Imports mutate settings, so they run under the settings lock with a fresh
  /// load — the daemon may be mid-refresh and holding a stale copy otherwise.
  func importing(_ detected: [DiscoveredCredential]) {
    let decisions = detected.map { ($0, decide($0)) }
    do {
      try daemon.editingSettings { transaction in
        for (credential, decision) in decisions {
          try apply(decision, to: credential, in: transaction)
        }
      }
    } catch {
      fail(error.localizedDescription)
    }
    if undecided {
      exit(1)
    }
  }

  if let wantedID {
    guard let match = daemon.detectedCredentials.first(where: { $0.stableID == wantedID }) else {
      fail("no discovered credential with id \(wantedID); run `llimit accounts import` to list ids")
    }
    importing([match])
    return
  }

  if importAll {
    importing(daemon.detectedCredentials)
    return
  }

  print("Discovered local logins:")
  for (offset, detected) in daemon.detectedCredentials.enumerated() {
    let state: String
    switch daemon.importMatch(for: detected, among: daemon.detectedCredentials) {
    case .alreadyImported:
      state = " (already imported)"
    case .newAccount:
      state = ""
    case .updateCandidates(let accountIDs):
      let names = accountIDs.compactMap { daemon.settings.account(withID: $0)?.resolvedDisplayName }
      state = " (differs from \(names.joined(separator: ", ")))"
    }
    print("  \(offset + 1). \(detected.provider.displayName) — \(detected.suggestedName) [\(detected.stableID)]")
    print("      from \(detected.sourceLabel)\(state)")
  }

  guard isatty(STDIN_FILENO) == 1 else {
    print("\nNon-interactive: re-run with --id <stable-id> or --all to import.")
    return
  }

  print("\nImport which? [1-\(daemon.detectedCredentials.count), a = all, Enter = none]: ", terminator: "")
  guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
    print("Nothing imported.")
    return
  }

  if answer.lowercased() == "a" {
    importing(daemon.detectedCredentials)
    return
  }

  guard
    let choice = Int(answer),
    daemon.detectedCredentials.indices.contains(choice - 1)
  else {
    fail("invalid selection: \(answer)")
  }
  importing([daemon.detectedCredentials[choice - 1]])
}

func accountsSetEnabled(_ fragment: String, enabled: Bool) {
  let daemon = makeDaemon()
  do {
    try daemon.editingSettings { transaction in
      let accountID = try daemon.resolveAccountID(fragment)
      try transaction.setAccountEnabled(accountID, enabled)
      let name = daemon.settings.account(withID: accountID)?.resolvedDisplayName ?? accountID
      print("\(name) \(enabled ? "enabled" : "disabled").")
    }
  } catch {
    fail(error.localizedDescription)
  }
}

func accountsRemove(_ fragment: String) {
  let daemon = makeDaemon()
  do {
    try daemon.editingSettings { transaction in
      let accountID = try daemon.resolveAccountID(fragment)
      let name = daemon.settings.account(withID: accountID)?.resolvedDisplayName ?? accountID
      try transaction.removeAccount(accountID)
      print("Removed \(name).")
    }
  } catch {
    fail(error.localizedDescription)
  }
}

func accountsUpdate(_ args: [String]) {
  guard let fragment = args.first else {
    fail("accounts update needs an account ID")
  }

  var name: String?
  var values: [String: String] = [:]
  var promptedKeys: [String] = []
  var index = 1
  while index < args.count {
    let arg = args[index]
    func takeValue() -> String {
      guard index + 1 < args.count else { fail("\(arg) needs a value") }
      index += 1
      return args[index]
    }
    switch arg {
    case "--name":
      name = takeValue()
    case "--set":
      // `--set key` without a value prompts for it, which keeps a secret out
      // of the shell history and the process list.
      let pair = takeValue()
      if let equals = pair.firstIndex(of: "=") {
        values[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
      } else {
        promptedKeys.append(pair)
      }
    default:
      fail("unknown option: \(arg)")
    }
    index += 1
  }

  guard name != nil || !values.isEmpty || !promptedKeys.isEmpty else {
    fail("accounts update needs --name or --set")
  }
  // Without a terminal nobody can answer the prompt, and reading nothing would
  // keep the old value while the command appeared to succeed.
  if let key = promptedKeys.first, isatty(STDIN_FILENO) != 1 {
    fail("--set \(key) without a value prompts for it, which needs a terminal; pass --set \(key)=<value> instead")
  }

  let daemon = makeDaemon()
  let accountID: String
  do {
    accountID = try daemon.resolveAccountID(fragment)
  } catch {
    fail(error.localizedDescription)
  }
  guard let account = daemon.settings.account(withID: accountID) else {
    fail(DaemonError.unknownAccount(fragment).localizedDescription)
  }

  // Reject a mistyped key before asking for its secret.
  let editable = QuotaDaemon.editableCredentialKeys(of: account)
  if let unknown = (Array(values.keys) + promptedKeys).sorted().first(where: { !editable.contains($0) }) {
    fail(DaemonError.unknownCredentialKey(unknown, provider: account.provider).localizedDescription)
  }

  for key in promptedKeys {
    let field = account.provider.credentialFields.first { $0.key == key }
    if let help = field?.help {
      print("  \(help)")
    }
    // Keys outside the form are hidden companions such as refresh tokens, so
    // they are read as secrets too.
    let value = readField(prompt: "\(field?.label ?? key) (Enter keeps the current value): ", secret: field?.isSecret ?? true)
    if !value.isEmpty {
      values[key] = value
    }
  }

  guard name != nil || !values.isEmpty else {
    print("No changes.")
    return
  }

  do {
    let updated = try daemon.editingSettings { transaction in
      try transaction.updateAccount(accountID, displayName: name, credentials: values.isEmpty ? .unchanged : .merging(values))
    }
    print("Updated \(updated.resolvedDisplayName) [\(updated.provider.rawValue)] — id \(updated.id)")
    noteMissingCredentials(of: updated)
  } catch {
    fail(error.localizedDescription)
  }
}

func accountsReimport(_ args: [String]) {
  guard let fragment = args.first else {
    fail("accounts reimport needs an account ID")
  }

  var stableID: String?
  var index = 1
  while index < args.count {
    switch args[index] {
    case "--from":
      guard index + 1 < args.count else { fail("--from needs a value") }
      index += 1
      stableID = args[index]
    default:
      fail("unknown option: \(args[index])")
    }
    index += 1
  }

  let daemon = makeDaemon()
  // Scan before taking the lock, so no files are read while it is held.
  daemon.scanForDetectedCredentials()
  do {
    let accountID = try daemon.resolveAccountID(fragment)
    let result = try daemon.editingSettings { transaction in
      try transaction.reimportAccount(accountID, from: stableID, among: daemon.detectedCredentials)
    }
    let name = daemon.settings.account(withID: accountID)?.resolvedDisplayName ?? accountID
    if result.changed {
      print("Updated \(name) from \(result.login.sourceLabel) — id \(accountID)")
    } else {
      print("\(name) already holds the login from \(result.login.sourceLabel); nothing changed.")
    }
  } catch {
    fail(error.localizedDescription)
  }
}

// MARK: - refresh / status / daemon

func runRefresh() async {
  let daemon = makeDaemon()
  do {
    // Load under the lock, then fetch unlocked — the daemon does the same per
    // cycle, so neither path can block the other for a network round-trip.
    // Token-refresh writes inside refreshNow re-lock and merge.
    try daemon.settingsLock.withLock {
      daemon.loadConfiguration()
    }
    await daemon.refreshNow()
  } catch {
    fail(error.localizedDescription)
  }
  print(StatusRenderer.humanReadable(snapshot: daemon.snapshot))
}

func runStatus(_ args: [String]) {
  let daemon = makeDaemon()
  if args.contains("--json") {
    print(StatusRenderer.waybarJSON(snapshot: daemon.snapshot))
  } else {
    print(StatusRenderer.humanReadable(snapshot: daemon.snapshot))
  }
}

/// Retained so the signal sources stay alive for the process lifetime.
var shutdownSignalSources: [DispatchSourceSignal] = []

/// SIGTERM/SIGINT cancel the refresh-loop task instead of using the default
/// disposition: `systemctl stop` then lets an in-flight refresh finish writing
/// its snapshot instead of cutting it off mid-write, and the loop exits at the
/// next cancellation point.
func installShutdownHandlers(cancel: @escaping () -> Void) {
  for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler(handler: cancel)
    source.resume()
    shutdownSignalSources.append(source)
  }
}

func runDaemon() async {
  let daemon = QuotaDaemon(paths: LinuxPaths())
  for line in ["[llimitd] settings: \(daemon.paths.settingsFileURL.path)",
               "[llimitd] snapshot: \(daemon.paths.snapshotFileURL.path)"] {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }
  let loop = Task { await daemon.runRefreshLoop() }
  installShutdownHandlers { loop.cancel() }
  await loop.value
}

// MARK: - terminal input

/// Reads a line, disabling terminal echo for secrets. Falls back to plain readLine
/// when stdin is not a TTY so piped input and scripts keep working.
func readField(prompt: String, secret: Bool) -> String {
  FileHandle.standardOutput.write(Data(prompt.utf8))

  guard secret, isatty(STDIN_FILENO) == 1 else {
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  // The shipped .deb is the static musl build, which has no Glibc module.
  #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
  var previous = termios()
  tcgetattr(STDIN_FILENO, &previous)
  var noEcho = previous
  noEcho.c_lflag &= ~tcflag_t(ECHO)
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &noEcho)
  let line = readLine() ?? ""
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &previous)
  FileHandle.standardOutput.write(Data("\n".utf8))
  return line.trimmingCharacters(in: .whitespacesAndNewlines)
  #else
  return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  #endif
}

// MARK: - entry point

guard let command = arguments.first else {
  printUsage()
  exit(1)
}

switch command {
case "accounts":
  runAccounts(Array(arguments.dropFirst()))
case "refresh":
  await runRefresh()
case "status":
  runStatus(Array(arguments.dropFirst()))
case "daemon":
  await runDaemon()
case "paths":
  let paths = LinuxPaths()
  print("settings: \(paths.settingsFileURL.path)")
  print("snapshot: \(paths.snapshotFileURL.path)")
  print("history:  \(paths.historyFileURL.path)")
case "help", "--help", "-h":
  printUsage()
default:
  fail("unknown command: \(command)")
}
