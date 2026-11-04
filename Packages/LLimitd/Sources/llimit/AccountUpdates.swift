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

func accountsUpdate(_ args: [String]) async {
  guard let fragment = args.first else { fail("accounts update needs an account ID") }
  var name: String?
  var values: [String: String] = [:]
  var promptedKeys: [String] = []
  var subscriptionCost: String?
  var subscriptionCurrency: String?
  var subscriptionPeriod: String?
  var index = 1
  while index < args.count {
    let arg = args[index]
    guard index + 1 < args.count else { fail("\(arg) needs a value") }
    index += 1
    switch arg {
    case "--name": name = args[index]
    case "--subscription-cost": subscriptionCost = args[index]
    case "--subscription-currency": subscriptionCurrency = args[index]
    case "--subscription-period": subscriptionPeriod = args[index]
    case "--set":
      let pair = args[index]
      if let equals = pair.firstIndex(of: "=") {
        values[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
      } else { promptedKeys.append(pair) }
    default: fail("unknown option: \(arg)")
    }
    index += 1
  }
  let hasPricingChange = subscriptionCost != nil || subscriptionCurrency != nil || subscriptionPeriod != nil
  guard name != nil || !values.isEmpty || !promptedKeys.isEmpty || hasPricingChange else {
    fail("accounts update needs --name, --set or subscription pricing options")
  }
  let clearPricing = subscriptionCost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off"
  if clearPricing, subscriptionCurrency != nil || subscriptionPeriod != nil {
    fail("--subscription-cost off cannot be combined with currency or period changes")
  }
  let amount: Double?
  if let subscriptionCost, !clearPricing {
    guard let parsed = Double(subscriptionCost.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.isFinite, parsed >= 0 else {
      fail("--subscription-cost needs a nonnegative finite amount, or off")
    }
    amount = parsed
  } else { amount = nil }
  let period: SubscriptionBillingPeriod?
  if let subscriptionPeriod {
    guard let parsed = SubscriptionBillingPeriod(rawValue: subscriptionPeriod) else {
      fail("--subscription-period must be monthly or yearly")
    }
    period = parsed
  } else { period = nil }
  if let subscriptionCurrency {
    do { _ = try SubscriptionPricing(amount: 0, currency: subscriptionCurrency).validated() }
    catch { fail(error.localizedDescription) }
  }
  func pricingChange(for account: ProviderAccount) throws -> SubscriptionPricingChange {
    guard hasPricingChange else { return .unchanged }
    if clearPricing { return .set(nil) }
    guard let amount = amount ?? account.subscriptionPricing?.amount else {
      throw SubscriptionPricingCLIError.missingAmount
    }
    return .set(try SubscriptionPricing(amount: amount,
      currency: subscriptionCurrency ?? account.subscriptionPricing?.currency ?? "USD",
      billingPeriod: period ?? account.subscriptionPricing?.billingPeriod ?? .monthly).validated())
  }
  if let key = promptedKeys.first, isatty(STDIN_FILENO) != 1 {
    fail("--set \(key) needs a terminal prompt or an explicit key=value")
  }

  let daemon = makeDaemon()
  do {
    let id = try daemon.resolveAccountID(fragment)
    guard let account = daemon.settings.account(withID: id) else { throw DaemonError.unknownAccount(fragment) }
    _ = try pricingChange(for: account)
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
    guard name != nil || !values.isEmpty || hasPricingChange else { print("No changes."); return }
    var verifiedMistralCredentials: [String: String]?
    if account.provider == .mistral, let header = values[CredentialField.mistralSessionCookies],
       !header.isEmpty {
      verifiedMistralCredentials = try await MistralQuotaClient(httpClient: URLSessionHTTPClient())
        .verifiedManualCredentials(header: header)
    }
    var verifiedLongcatCredentials: [String: String]?
    if account.provider == .longcat, let header = values[CredentialField.longcatSessionCookies],
       !header.isEmpty {
      verifiedLongcatCredentials = try await LongcatQuotaClient(httpClient: URLSessionHTTPClient())
        .verifiedManualCredentials(header: header)
    }
    let updated = try daemon.editingSettings {
      guard let latest = daemon.settings.account(withID: id) else { throw DaemonError.unknownAccount(fragment) }
      let pricing = try pricingChange(for: latest)
      if let verifiedMistralCredentials {
        guard daemon.settings.account(withID: id)?.credentials == account.credentials else {
          throw ProviderClientError(kind: .api, message: "The account changed while Mistral was being verified. Try again.")
        }
        return try $0.updateAccount(id, displayName: name, credentials: .replacing(with: verifiedMistralCredentials), subscriptionPricing: pricing)
      }
      if let verifiedLongcatCredentials {
        guard daemon.settings.account(withID: id)?.credentials == account.credentials else {
          throw ProviderClientError(kind: .api, message: "The account changed while Longcat was being verified. Try again.")
        }
        return try $0.updateAccount(id, displayName: name, credentials: .replacing(with: verifiedLongcatCredentials), subscriptionPricing: pricing)
      }
      return try $0.updateAccount(id, displayName: name, credentials: values.isEmpty ? .unchanged : .merging(values), subscriptionPricing: pricing)
    }
    print("Updated \(updated.resolvedDisplayName) [\(updated.provider.rawValue)] — id \(updated.id)")
    noteMissingCredentials(of: updated)
  } catch { fail(error.localizedDescription) }
}

private enum SubscriptionPricingCLIError: LocalizedError {
  case missingAmount

  var errorDescription: String? {
    "Set --subscription-cost before changing the currency or billing period."
  }
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
