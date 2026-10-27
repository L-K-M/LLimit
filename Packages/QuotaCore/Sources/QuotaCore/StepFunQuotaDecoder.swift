import Foundation

/// Schema verified in StepFun's global console bundles on 2026-10-27:
/// 8300-80e7d8753e1d65ea.js (protobuf definitions) and
/// 5731-6a1cbb3d71daa6f0.js (credit and legacy window display).
/// Remaining fractions are independent; subscription and top-up percentages
/// must never be added. Expiry does not establish a recurring reset.
enum StepFunQuotaDecoder {
  static func decode(_ data: Data, configuration: ProviderRuntimeConfiguration, now: Date) throws -> ProviderUsage {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let envelope: Envelope
    do { envelope = try decoder.decode(Envelope.self, from: data) }
    catch { throw invalidResponse }
    if ["unauthenticated", "permission_denied"].contains(envelope.code) {
      throw StepFunQuotaClient.authenticationFailure
    }
    guard let status = envelope.status else { throw invalidResponse }
    switch status.value {
    case "1", "CODE_OK": break
    case "5", "CODE_TOO_MANY":
      throw ProviderClientError(kind: .rateLimit, message: "StepFun is rate limiting console usage requests. Try again later.")
    default:
      throw ProviderClientError(kind: .api, message: "StepFun rejected the quota request. Check your Step Plan in the console.")
    }

    let quota: Quota
    do { quota = try decoder.decode(Quota.self, from: data) }
    catch { throw invalidResponse }
    let family = quota.planFamily?.value ?? "0"
    let metrics: [UsageMetric]
    switch family {
    case "2", "3", "PLAN_FAMILY_TOKEN", "PLAN_FAMILY_TOKEN_V3":
      guard let credits = quota.planCreditRateLimit else { throw invalidResponse }
      metrics = try creditMetrics(credits, now: now)
    case "0", "1", "PLAN_FAMILY_UNSPECIFIED", "PLAN_FAMILY_CODING":
      // Some responses predate plan_family. A credit message still takes
      // precedence over default zero-valued legacy fields in those responses.
      if let credits = quota.planCreditRateLimit {
        metrics = try creditMetrics(credits, now: now)
      } else {
        metrics = try [
          rateMetric(quota.fiveHourUsageLeftRate, reset: quota.fiveHourUsageResetTime,
            id: "five-hour", label: "5-hour limit", duration: 18_000, now: now),
          rateMetric(quota.weeklyUsageLeftRate, reset: quota.weeklyUsageResetTime,
            id: "weekly", label: "Weekly limit", duration: 604_800, now: now)
        ].compactMap { $0 }
      }
    default: throw invalidResponse
    }
    guard !metrics.isEmpty else { throw invalidResponse }
    let maxUsage = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    return ProviderUsage(accountID: configuration.accountID, provider: .stepFun,
      title: configuration.displayName, subtitle: "Step Plan", metrics: metrics,
      maxUsagePercent: maxUsage, warning: maxUsage.map { $0 >= 80 } == true ? "High usage" : nil,
      fetchedAt: now)
  }

  private static func rateMetric(_ fraction: Double?, reset: Number?, id: String,
                                  label: String, duration: Int, now: Date) throws -> UsageMetric? {
    let resetAt = try timestamp(reset)
    // Protobuf JSON omits scalar defaults. A reported reset establishes the
    // window even when its exhausted (zero) remaining fraction was omitted.
    guard let fraction = fraction ?? resetAt.map({ _ in 0 }) else { return nil }
    return UsageMetric(id: id, label: label, remainingPercent: try percentage(fraction),
      resetAt: resetAt, resetIn: resetAt.map { formatResetCountdown(to: $0, now: now) },
      windowSeconds: duration)
  }

  private static func creditMetrics(_ credits: Credits, now: Date) throws -> [UsageMetric] {
    var subscription = Counts()
    var topup = Counts()
    var subscriptionResets: [Date] = []
    var expiries: [Date] = []
    for bucket in credits.creditBuckets ?? [] {
      let total = try nonnegative(bucket.creditTotal) ?? 0
      let residual = try nonnegative(bucket.creditResidual) ?? 0
      guard residual <= total else { throw invalidResponse }
      let expiry = try timestamp(bucket.expireAt)
      let reset = try timestamp(bucket.nextResetAt)
      let type = bucket.type?.value ?? "0"
      switch type {
      case "1", "TYPE_SUBSCRIPTION":
        // Subscription expiry is not a recurring reset date.
        if expiry.map({ $0 <= now }) == true { continue }
        try subscription.add(total: total, residual: residual)
        if let reset { subscriptionResets.append(reset) }
      case "2", "TYPE_TOPUP":
        // Expired top-ups are no longer available even if retained in a
        // response. Each live bucket contributes its own numerator/denominator.
        if expiry.map({ $0 <= now }) == true { continue }
        try topup.add(total: total, residual: residual)
        if let expiry { expiries.append(expiry) }
      default: throw invalidResponse
      }
    }

    var metrics: [UsageMetric] = []
    let reset = try timestamp(credits.subscriptionCreditResetTime) ?? subscriptionResets.min()
    // A reset or subscription bucket establishes an omitted protobuf zero.
    // Optional bucket counts must not revive an exhausted subscription.
    let fraction = credits.subscriptionCreditLeftRate ?? ((reset != nil || subscription.total > 0) ? 0.0 : nil)
    if let fraction {
      metrics.append(try creditMetric(id: "monthly-credits", label: "Monthly plan credits", fraction: fraction,
        counts: subscription, reset: reset, detail: nil, now: now))
    }
    // Reported top-up buckets win over the aggregate fraction, which can still
    // include expired buckets. Zero-size buckets never establish a denominator.
    let topupFraction = topup.fraction ?? ((credits.creditBuckets?.contains {
      ["2", "TYPE_TOPUP"].contains($0.type?.value ?? "")
    } == true) ? nil : credits.topupCreditLeftRate)
    if let topupFraction {
      let expiryText = expiries.min().map { "Next top-up expiry: \(ISO8601DateFormatter().string(from: $0))" }
      metrics.append(try creditMetric(id: "topup-credits", label: "Top-up credits", fraction: topupFraction,
        counts: topup, reset: nil, detail: expiryText, now: now))
    }
    // Validate explicit fractions even if counts supplied the displayed value.
    if let rate = credits.subscriptionCreditLeftRate { _ = try percentage(rate) }
    if let rate = credits.topupCreditLeftRate { _ = try percentage(rate) }
    return metrics
  }

  private static func creditMetric(id: String, label: String, fraction: Double, counts: Counts,
                                   reset: Date?, detail: String?, now: Date) throws -> UsageMetric {
    let remaining = try percentage(fraction)
    let coherentCounts = counts.fraction.map { abs($0 - fraction) <= 0.01 } == true
    return UsageMetric(id: id, label: label, remainingPercent: remaining,
      remainingAmount: coherentCounts ? counts.residual : nil,
      usedDisplay: coherentCounts ? "\(creditText(counts.total - counts.residual)) credits" : nil,
      totalDisplay: coherentCounts ? "\(creditText(counts.total)) credits" : nil,
      resetAt: reset, resetIn: reset.map { formatResetCountdown(to: $0, now: now) }, detail: detail)
  }

  private static func percentage(_ fraction: Double) throws -> Int {
    guard fraction.isFinite, (0...1).contains(fraction) else { throw invalidResponse }
    return Int((fraction * 100).rounded())
  }

  private static func nonnegative(_ number: Number?) throws -> Double? {
    guard let number else { return nil }
    guard number.value.isFinite, number.value >= 0, number.value.rounded(.down) == number.value else {
      throw invalidResponse
    }
    return number.value
  }

  private static func timestamp(_ number: Number?) throws -> Date? {
    guard let seconds = try nonnegative(number), seconds != 0 else { return nil }
    guard seconds <= 253_402_300_799 else { throw invalidResponse }
    return Date(timeIntervalSince1970: seconds)
  }

  private static func creditText(_ value: Double) -> String {
    // formatIntLike converts to Int and cannot represent the upper int64 range.
    value < Double(Int.max) ? (formatIntLike(value) ?? "0") : String(format: "%.0f", value)
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "StepFun returned incomplete or invalid Step Plan usage data. Try again later.")
  }

  private struct Counts {
    var total = 0.0
    var residual = 0.0
    var fraction: Double? { total > 0 ? residual / total : nil }

    mutating func add(total: Double, residual: Double) throws {
      self.total += total
      self.residual += residual
      guard self.total.isFinite, self.residual.isFinite else { throw invalidResponse }
    }
  }

  private struct Envelope: Decodable { let status: EnumValue?; let code: String? }
  private struct Quota: Decodable {
    let planFamily: EnumValue?
    let fiveHourUsageLeftRate: Double?
    let fiveHourUsageResetTime: Number?
    let weeklyUsageLeftRate: Double?
    let weeklyUsageResetTime: Number?
    let planCreditRateLimit: Credits?
  }
  private struct Credits: Decodable {
    let subscriptionCreditLeftRate: Double?
    let subscriptionCreditResetTime: Number?
    let topupCreditLeftRate: Double?
    let creditBuckets: [Bucket]?
  }
  private struct Bucket: Decodable {
    let type: EnumValue?
    let creditTotal: Number?
    let creditResidual: Number?
    let expireAt: Number?
    let nextResetAt: Number?
  }
  private struct Number: Decodable {
    let value: Double
    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let text = try? container.decode(String.self), let number = Double(text), number.isFinite {
        value = number
      } else { value = try container.decode(Double.self) }
    }
  }
  private struct EnumValue: Decodable {
    let value: String
    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let text = try? container.decode(String.self) { value = text }
      else { value = String(try container.decode(Int.self)) }
    }
  }
}
