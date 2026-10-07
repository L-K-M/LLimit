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

func accountsUpdate(_ args: [String]) {
  guard let fragment = args.first else { fail("accounts update needs an account ID") }
  var name: String?
  var values: [String: String] = [:]
  var promptedKeys: [String] = []
  var index = 1
  while index < args.count {
    let arg = args[index]
    guard index + 1 < args.count else { fail("\(arg) needs a value") }
    index += 1
    switch arg {
    case "--name": name = args[index]
    case "--set":
      let pair = args[index]
      if let equals = pair.firstIndex(of: "=") {
        values[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
      } else { promptedKeys.append(pair) }
    default: fail("unknown option: \(arg)")
    }
    index += 1
  }
  guard name != nil || !values.isEmpty || !promptedKeys.isEmpty else { fail("accounts update needs --name or --set") }
  if let key = promptedKeys.first, isatty(STDIN_FILENO) != 1 {
    fail("--set \(key) needs a terminal prompt or an explicit key=value")
  }

  let daemon = makeDaemon()
  do {
    let id = try daemon.resolveAccountID(fragment)
    guard let account = daemon.settings.account(withID: id) else { throw DaemonError.unknownAccount(fragment) }
    let editable = QuotaDaemon.editableCredentialKeys(of: account)
    if let unknown = (Array(values.keys) + promptedKeys).sorted().first(where: { !editable.contains($0) }) {
      throw DaemonError.unknownCredentialKey(unknown, provider: account.provider)
    }
    // Prompt before locking; only the final write needs a fresh settings transaction.
    for key in promptedKeys {
      let field = account.provider.credentialFields.first { $0.key == key }
      if let help = field?.help { print("  \(help)") }
      let value = readField(prompt: "\(field?.label ?? key) (Enter keeps current value): ", secret: field?.isSecret ?? true)
      if !value.isEmpty { values[key] = value }
    }
    guard name != nil || !values.isEmpty else { print("No changes."); return }
    let updated = try daemon.editingSettings {
      try $0.updateAccount(id, displayName: name, credentials: values.isEmpty ? .unchanged : .merging(values))
    }
    print("Updated \(updated.resolvedDisplayName) [\(updated.provider.rawValue)] — id \(updated.id)")
    noteMissingCredentials(of: updated)
  } catch { fail(error.localizedDescription) }
}

func accountsReimport(_ args: [String]) {
  guard let fragment = args.first else { fail("accounts reimport needs an account ID") }
  var stableID: String?
  var index = 1
  while index < args.count {
    guard args[index] == "--from" else { fail("unknown option: \(args[index])") }
    guard index + 1 < args.count else { fail("--from needs a value") }
    index += 1
    stableID = args[index]
    index += 1
  }
  let daemon = makeDaemon()
  daemon.scanForDetectedCredentials()
  do {
    let result = try daemon.editingSettings { transaction in
      let id = try daemon.resolveAccountID(fragment)
      return try transaction.reimportAccount(id, from: stableID, among: daemon.detectedCredentials)
    }
    print(result.changed ? "Updated from \(result.login.sourceLabel)." : "Login unchanged.")
  } catch { fail(error.localizedDescription) }
}
