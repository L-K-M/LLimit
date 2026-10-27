import Foundation

/// The personal Plan API used by Step Code. Its percentages are used percentages,
/// timestamps are milliseconds, and credit counts are exact decimal strings.
enum StepFunPlanQuotaDecoder {
  static func decode(_ data: Data, configuration: ProviderRuntimeConfiguration, now: Date) throws -> ProviderUsage {
    let snapshot: Snapshot
    do {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      snapshot = try decoder.decode(Snapshot.self, from: data)
    } catch { throw invalidResponse }
    guard snapshot.schemaVersion == 1, snapshot.scope == "personal_account",
          validID(snapshot.account.id), snapshot.observedAtMs > 0,
          snapshot.observedAtMs <= now.timeIntervalSince1970 * 1_000 + 120_000,
          snapshot.observedAtMs.rounded() == snapshot.observedAtMs,
          ["known", "unavailable"].contains(snapshot.plan.state),
          ["coding", "token", "none"].contains(snapshot.plan.family),
          snapshot.quota.state == "known", let buckets = snapshot.quota.creditBuckets,
          buckets.count <= 256 else { throw invalidResponse }
    if let expected = configuration.credentials[CredentialField.stepFunUserID], !expected.isEmpty,
       (try? count(expected)) != (try? count(snapshot.account.id)) {
      throw ProviderClientError(kind: .auth, message: "StepFun returned a different account. Reimport your Step Code login or reconnect StepFun.")
    }
    if let subscription = snapshot.plan.subscription {
      guard validID(subscription.id) else { throw invalidResponse }
      _ = try timestamp(subscription.expiresAtMs)
    }
    guard snapshot.plan.state != "unavailable" || (snapshot.plan.name == nil && snapshot.plan.subscription == nil),
          snapshot.plan.family != "none" || (snapshot.plan.subscription == nil && !snapshot.quota.allowed) else {
      throw invalidResponse
    }
    let metrics: [UsageMetric]
    switch snapshot.plan.family {
    case "coding":
      guard buckets.isEmpty, snapshot.quota.windows.count == 2,
            Set(snapshot.quota.windows.map(\.id)) == Set(["five_hour", "weekly"]) else { throw invalidResponse }
      metrics = try snapshot.quota.windows.map { window in
        let used = try percentage(window.usedPercent)
        guard window.limited == (used != nil) else { throw invalidResponse }
        let reset = try timestamp(window.resetsAtMs)
        let hourly = window.id == "five_hour"
        return UsageMetric(id: hourly ? "five-hour" : "weekly", label: hourly ? "5-hour limit" : "Weekly limit",
          remainingPercent: used.map { Int((100 - $0).rounded()) }, resetAt: reset,
          resetIn: reset.map { formatResetCountdown(to: $0, now: now) },
          windowSeconds: hourly ? 18_000 : 604_800, isUnlimited: !window.limited)
      }
    case "token":
      guard snapshot.quota.windows.isEmpty else { throw invalidResponse }
      metrics = try creditMetrics(buckets, now: now)
      guard !metrics.isEmpty else {
        throw ProviderClientError(kind: .api, message: "StepFun reports no active personal Step Plan credits for this account.")
      }
    default:
      guard snapshot.quota.windows.isEmpty, buckets.isEmpty else { throw invalidResponse }
      throw ProviderClientError(kind: .api, message: "StepFun reports no personal Step Plan for this account.")
    }
    guard !metrics.isEmpty else { throw invalidResponse }
    let maxUsage = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    return ProviderUsage(accountID: configuration.accountID, provider: .stepFun,
      title: configuration.displayName, subtitle: "Step Plan", metrics: metrics,
      maxUsagePercent: maxUsage, warning: maxUsage.map { $0 >= 80 } == true ? "High usage" : nil, fetchedAt: now)
  }

  private static func creditMetrics(_ buckets: [Bucket], now: Date) throws -> [UsageMetric] {
    var groups: [String: Credits] = [:]
    for bucket in buckets {
      guard ["subscription", "topup"].contains(bucket.type) else { throw invalidResponse }
      let total = try count(bucket.total), remaining = try count(bucket.remaining)
      guard remaining <= total else { throw invalidResponse }
      let used = try percentage(bucket.usedPercent)
      let expiry = try timestamp(bucket.expiresAtMs), reset = try timestamp(bucket.resetsAtMs)
      if expiry.map({ $0 <= now }) == true { continue }
      var group = groups[bucket.type] ?? Credits()
      group.total += total
      group.remaining += remaining
      // Each bucket's explicit percentage wins over count-derived percentages.
      if let used { group.weightedRemaining += total * Decimal((100 - used) / 100) }
      else { group.hasPercent = false }
      if let reset { group.resets.append(reset) }
      if let expiry { group.expiries.append(expiry) }
      groups[bucket.type] = group
    }
    return ["subscription", "topup"].compactMap { type in
      guard let group = groups[type] else { return nil }
      let subscription = type == "subscription"
      let reset = subscription ? group.resets.min() : nil
      let percent = group.hasPercent && group.total > 0
        ? Int((NSDecimalNumber(decimal: group.weightedRemaining / group.total).doubleValue * 100).rounded()) : nil
      let detail = !subscription ? group.expiries.min().map {
        "Next top-up expiry: \(ISO8601DateFormatter().string(from: $0))"
      } : nil
      return UsageMetric(id: subscription ? "monthly-credits" : "topup-credits",
        label: subscription ? "Monthly plan credits" : "Top-up credits", remainingPercent: percent,
        remainingAmount: NSDecimalNumber(decimal: group.remaining).doubleValue,
        usedDisplay: "\(NSDecimalNumber(decimal: group.total - group.remaining).stringValue) credits",
        totalDisplay: "\(NSDecimalNumber(decimal: group.total).stringValue) credits",
        resetAt: reset, resetIn: reset.map { formatResetCountdown(to: $0, now: now) }, detail: detail)
    }
  }

  private static func validID(_ value: String) -> Bool {
    guard let number = try? count(value) else { return false }
    return number > 0
  }
  private static func count(_ value: String) throws -> Decimal {
    guard (1...19).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }),
          let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
          number <= Decimal(Int64.max) else { throw invalidResponse }
    return number
  }
  private static func percentage(_ value: Double?) throws -> Double? {
    guard let value else { return nil }
    guard value.isFinite, (0...100).contains(value) else { throw invalidResponse }
    return value
  }
  private static func timestamp(_ value: Double?) throws -> Date? {
    guard let value else { return nil }
    guard value.isFinite, value > 0, value.rounded() == value, value <= 8_640_000_000_000_000 else { throw invalidResponse }
    return Date(timeIntervalSince1970: value / 1_000)
  }
  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "StepFun returned incomplete or invalid personal Plan usage data. Try again later.")
  }
  private struct Credits {
    var total = Decimal(0)
    var remaining = Decimal(0)
    var weightedRemaining = Decimal(0)
    var hasPercent = true
    var resets: [Date] = []
    var expiries: [Date] = []
  }
  private struct Snapshot: Decodable {
    let schemaVersion: Int
    let observedAtMs: Double
    let scope: String
    let account: Account
    let plan: Plan
    let quota: Quota
  }
  private struct Account: Decodable { let id: String }
  private struct Plan: Decodable {
    let state: String
    let family: String
    let name: String?
    let subscription: Subscription?
  }
  private struct Subscription: Decodable { let id: String; let expiresAtMs: Double? }
  private struct Quota: Decodable {
    let state: String
    let allowed: Bool
    let windows: [Window]
    let creditBuckets: [Bucket]?
  }
  private struct Window: Decodable { let id: String; let limited: Bool; let usedPercent: Double?; let resetsAtMs: Double? }
  private struct Bucket: Decodable {
    let type: String
    let total: String
    let remaining: String
    let usedPercent: Double?
    let resetsAtMs: Double?
    let expiresAtMs: Double?
  }
}
