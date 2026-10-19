import Foundation

/// Personal Token Plan console schema observed in the official public UI:
/// main.1097440ce549c686.chunk.js (module 4879) and
/// 279.384318a602760797.chunk.js (module 70793), 2026-10-19.
/// `percent` is the used fraction. `currentPeriodEnd` is displayed as expiry,
/// and does not establish either a recurring quota reset or a window length.
enum MiMoTokenPlanDecoder {
  static func decode(
    detailData: Data,
    usageData: Data,
    accountID: String,
    title: String,
    now: Date
  ) throws -> ProviderUsage {
    let detail: Detail = try payload(from: detailData)
    guard let planCode = detail.planCode, validText(planCode, limit: 128) != nil,
          detail.expired != true else {
      throw ProviderClientError(kind: .api, message: "MiMo reported no active Token Plan. Check your subscription in the console.")
    }
    let usage: Usage = try payload(from: usageData)
    guard let items = usage.usage?.items, !items.isEmpty else { throw invalidResponse }

    var seen = Set<String>()
    var rows: [(item: Item, name: String)] = []
    for item in items {
      guard let name = validText(item.name, limit: 128), seen.insert(name).inserted else {
        throw invalidResponse
      }
      if let used = item.used, !used.isFinite || used < 0 { throw invalidResponse }
      if let limit = item.limit, !limit.isFinite || limit < 0 { throw invalidResponse }
      if let percent = item.percent, !percent.isFinite || percent < 0 { throw invalidResponse }
      if name == "compensation_total_token", item.limit == 0 { continue }
      rows.append((item, name))
    }
    guard !rows.isEmpty else { throw invalidResponse }
    rows.sort {
      if isBonus($0.name) != isBonus($1.name) { return !isBonus($0.name) }
      return $0.name < $1.name
    }
    let ordinaryCount = rows.filter { !isBonus($0.name) }.count
    let expiry = expiryDetail(detail.currentPeriodEnd)
    let metrics = try rows.map { row -> UsageMetric in
      let item = row.item
      let counts = validCounts(item)
      let fraction = item.percent ?? counts.map { $0.used / $0.limit }
      guard let fraction, !fraction.isNaN, fraction >= 0 else { throw invalidResponse }
      // Clamp before multiplication so large but finite overage values cannot
      // overflow. A tiny positive denominator can produce infinite overage.
      let remaining = Int(((1 - min(1, fraction)) * 100).rounded())
      let coherentCounts = counts.flatMap { counts -> (used: Double, limit: Double)? in
        guard item.percent != nil else { return counts }
        let countFraction = min(1, counts.used / counts.limit)
        return abs(countFraction - min(1, fraction)) <= 0.01 ? counts : nil
      }
      let label: String
      if isBonus(row.name) {
        label = "Bonus credits"
      } else if ordinaryCount == 1 {
        label = "Plan credits"
      } else {
        label = "Plan credits (\(row.name.replacingOccurrences(of: "_", with: " ")))"
      }
      return UsageMetric(
        id: "plan-\(row.name)", label: label, remainingPercent: remaining,
        usedDisplay: coherentCounts.map { "\(creditText($0.used)) credits" },
        totalDisplay: coherentCounts.map { "\(creditText($0.limit)) credits" },
        detail: expiry
      )
    }
    let maxUsage = metrics.compactMap(\.remainingPercent).map { 100 - $0 }.max()
    return ProviderUsage(
      accountID: accountID, provider: .xiaomiMiMo, title: title,
      subtitle: validText(detail.planName, limit: 128) ?? "Token Plan", metrics: metrics,
      maxUsagePercent: maxUsage, warning: maxUsage.map { $0 >= 80 } == true ? "High usage" : nil,
      fetchedAt: now
    )
  }

  private static func payload<Value: Decodable>(from data: Data) throws -> Value {
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw invalidResponse
    }
    switch envelope.code {
    case 0, 200:
      break
    case 429, 400429:
      throw ProviderClientError(kind: .rateLimit, message: "MiMo is rate limiting console usage requests. Try again later.")
    default:
      throw ProviderClientError(kind: .api, message: "MiMo rejected the console usage request. Check your Token Plan in the console.")
    }
    do {
      return try JSONDecoder().decode(Payload<Value>.self, from: data).data
    } catch {
      throw invalidResponse
    }
  }

  private static func validCounts(_ item: Item) -> (used: Double, limit: Double)? {
    guard let used = item.used, let limit = item.limit,
          used.isFinite, used >= 0, limit.isFinite, limit > 0 else { return nil }
    return (used, limit)
  }

  private static func validText(_ text: String?, limit: Int) -> String? {
    guard let text, text.utf8.count <= limit * 4, text.count <= limit,
          text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func creditText(_ value: Double) -> String {
    if value >= Double(Int.max) { return String(value) }
    return formatIntLike(value) ?? "0"
  }

  private static func isBonus(_ name: String) -> Bool { name == "compensation_total_token" }

  private static func expiryDetail(_ text: String?) -> String? {
    guard let text = validText(text, limit: 64) else { return nil }
    let pattern = #"^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?:[T ](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:[Zz]|[+-](?:[01]\d|2[0-3]):[0-5]\d)?)?$"#
    guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let dateText = String(text.prefix(10))
    let calendar = DateFormatter()
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)
    calendar.dateFormat = "yyyy-MM-dd"
    calendar.isLenient = false
    guard let date = calendar.date(from: dateText), calendar.string(from: date) == dateText else { return nil }
    // Preserve the server's precision and timezone, including an absent zone.
    // Calendar validation above does not turn an unzoned clock into UTC.
    return "Plan expires \(text)"
  }

  private static var invalidResponse: ProviderClientError {
    ProviderClientError(kind: .decoding, message: "MiMo returned incomplete or invalid Token Plan usage data. Try again later.")
  }

  private struct Envelope: Decodable { let code: Int }
  private struct Payload<Value: Decodable>: Decodable { let data: Value }
  private struct Detail: Decodable {
    let planCode: String?
    let planName: String?
    let expired: Bool?
    let currentPeriodEnd: String?
  }
  private struct Usage: Decodable {
    struct Window: Decodable { let items: [Item]? }
    let usage: Window?
  }
  private struct Item: Decodable {
    let name: String
    let used: Double?
    let limit: Double?
    let percent: Double?
  }
}
