import Foundation
import QuotaCore
import LLimitdCore
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
      llimit refresh
      llimit status [--json]
      llimit daemon
      llimit paths

    Providers: \(QuotaProvider.allCases.map(\.rawValue).joined(separator: ", "))
    Account IDs may be shortened to any unique prefix.
    """
  )
}

func makeDaemon() -> QuotaDaemon {
  let daemon = QuotaDaemon(paths: LinuxPaths())
  daemon.loadConfiguration()
  return daemon
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

  let daemon = makeDaemon()
  let account = daemon.addAccount(provider: provider, displayName: name, credentials: credentials)
  print("Added \(account.resolvedDisplayName) [\(account.provider.rawValue)] — id \(account.id)")

  let missing = account.missingCredentialLabels
  if !missing.isEmpty {
    print("Note: still missing \(missing.joined(separator: ", ")); the account will be skipped until complete.")
  }
}

func accountsImport(_ args: [String]) {
  var wantedID: String?
  var importAll = false

  var index = 0
  while index < args.count {
    switch args[index] {
    case "--id":
      guard index + 1 < args.count else { fail("--id needs a value") }
      index += 1
      wantedID = args[index]
    case "--all":
      importAll = true
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

  func importOne(_ detected: DiscoveredCredential) {
    if daemon.isDetectedCredentialImported(detected) {
      print("\(detected.provider.displayName) from \(detected.sourceLabel): already imported, skipping.")
      return
    }
    let account = daemon.importAccount(from: detected)
    print("Imported \(account.resolvedDisplayName) [\(account.provider.rawValue)] from \(detected.sourceLabel) — id \(account.id)")
  }

  if let wantedID {
    guard let match = daemon.detectedCredentials.first(where: { $0.stableID == wantedID }) else {
      fail("no discovered credential with id \(wantedID); run `llimit accounts import` to list ids")
    }
    importOne(match)
    return
  }

  if importAll {
    for detected in daemon.detectedCredentials {
      importOne(detected)
    }
    return
  }

  print("Discovered local logins:")
  for (offset, detected) in daemon.detectedCredentials.enumerated() {
    let imported = daemon.isDetectedCredentialImported(detected) ? " (already imported)" : ""
    print("  \(offset + 1). \(detected.provider.displayName) — \(detected.suggestedName) [\(detected.stableID)]")
    print("      from \(detected.sourceLabel)\(imported)")
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
    for detected in daemon.detectedCredentials {
      importOne(detected)
    }
    return
  }

  guard
    let choice = Int(answer),
    daemon.detectedCredentials.indices.contains(choice - 1)
  else {
    fail("invalid selection: \(answer)")
  }
  importOne(daemon.detectedCredentials[choice - 1])
}

func accountsSetEnabled(_ fragment: String, enabled: Bool) {
  let daemon = makeDaemon()
  guard let accountID = daemon.resolveAccountID(fragment) else {
    fail("no account matching \"\(fragment)\" (or the prefix is ambiguous)")
  }
  do {
    try daemon.setAccountEnabled(accountID, enabled)
    let name = daemon.settings.account(withID: accountID)?.resolvedDisplayName ?? accountID
    print("\(name) \(enabled ? "enabled" : "disabled").")
  } catch {
    fail(error.localizedDescription)
  }
}

func accountsRemove(_ fragment: String) {
  let daemon = makeDaemon()
  guard let accountID = daemon.resolveAccountID(fragment) else {
    fail("no account matching \"\(fragment)\" (or the prefix is ambiguous)")
  }
  let name = daemon.settings.account(withID: accountID)?.resolvedDisplayName ?? accountID
  do {
    try daemon.removeAccount(accountID)
    print("Removed \(name).")
  } catch {
    fail(error.localizedDescription)
  }
}

// MARK: - refresh / status / daemon

func runRefresh() async {
  let daemon = makeDaemon()
  await daemon.refreshNow()
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

func runDaemon() async {
  let daemon = QuotaDaemon(paths: LinuxPaths())
  for line in ["[llimitd] settings: \(daemon.paths.settingsFileURL.path)",
               "[llimitd] snapshot: \(daemon.paths.snapshotFileURL.path)"] {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }
  await daemon.runRefreshLoop()
}

// MARK: - terminal input

/// Reads a line, disabling terminal echo for secrets. Falls back to plain readLine
/// when stdin is not a TTY so piped input and scripts keep working.
func readField(prompt: String, secret: Bool) -> String {
  FileHandle.standardOutput.write(Data(prompt.utf8))

  guard secret, isatty(STDIN_FILENO) == 1 else {
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  #if canImport(Glibc) || canImport(Darwin)
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
