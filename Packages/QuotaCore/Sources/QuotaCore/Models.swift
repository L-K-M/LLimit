import Foundation

public enum QuotaProvider: String, CaseIterable, Codable, Sendable {
  case anthropic = "anthropic"
  case openAI = "openai"
  case gitHubCopilot = "github-copilot"
  case zhipu = "zhipu"
  case zai = "zai"
  case googleAntigravity = "google-antigravity"

  public var displayName: String {
    switch self {
    case .anthropic:
      return "Claude"
    case .openAI:
      return "OpenAI"
    case .zhipu:
      return "Zhipu AI"
    case .zai:
      return "Z.ai"
    case .googleAntigravity:
      return "Google Cloud"
    case .gitHubCopilot:
      return "GitHub Copilot"
    }
  }
}

public struct CredentialFieldDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String { key }
  public var key: String
  public var label: String
  public var isSecret: Bool
  public var isRequired: Bool
  public var help: String?

  public init(
    key: String,
    label: String,
    isSecret: Bool = true,
    isRequired: Bool = true,
    help: String? = nil
  ) {
    self.key = key
    self.label = label
    self.isSecret = isSecret
    self.isRequired = isRequired
    self.help = help
  }
}

public extension QuotaProvider {
  var credentialFields: [CredentialFieldDescriptor] {
    switch self {
    case .anthropic:
      return [
        CredentialFieldDescriptor(
          key: CredentialField.anthropicAccessToken,
          label: "OAuth access token",
          help: "Auto-detected from Claude Code (Keychain or ~/.claude/.credentials.json)."
        )
      ]
    case .openAI:
      return [
        CredentialFieldDescriptor(
          key: CredentialField.openAIAccessToken,
          label: "Access token",
          help: "Use a ChatGPT web session access token. Platform API keys are not accepted by this quota endpoint."
        ),
        CredentialFieldDescriptor(
          key: CredentialField.openAIAccountID,
          label: "Account ID",
          isSecret: false,
          isRequired: false,
          help: "Optional ChatGPT-Account-Id header for multi-account sessions."
        )
      ]
    case .zhipu:
      return [
        CredentialFieldDescriptor(
          key: CredentialField.zhipuAPIKey,
          label: "API key"
        )
      ]
    case .zai:
      return [
        CredentialFieldDescriptor(
          key: CredentialField.zaiAPIKey,
          label: "API key"
        )
      ]
    case .googleAntigravity:
      return [
        CredentialFieldDescriptor(
          key: CredentialField.googleRefreshToken,
          label: "Refresh token"
        ),
        CredentialFieldDescriptor(
          key: CredentialField.googleProjectID,
          label: "Project ID",
          isSecret: false
        ),
        CredentialFieldDescriptor(
          key: CredentialField.googleEmail,
          label: "Email",
          isSecret: false,
          isRequired: false
        )
      ]
    case .gitHubCopilot:
      return [
        CredentialFieldDescriptor(
          key: CredentialField.copilotPATToken,
          label: "Personal access token",
          isRequired: false,
          help: "Used with username for GitHub's billing usage API."
        ),
        CredentialFieldDescriptor(
          key: CredentialField.copilotUsername,
          label: "GitHub username",
          isSecret: false,
          isRequired: false
        ),
        CredentialFieldDescriptor(
          key: CredentialField.copilotTier,
          label: "Plan tier",
          isSecret: false,
          isRequired: false,
          help: "Optional: free, pro, pro+, business, or enterprise."
        ),
        CredentialFieldDescriptor(
          key: CredentialField.copilotOAuthToken,
          label: "OAuth token",
          isRequired: false,
          help: "Alternative to PAT plus username."
        )
      ]
    }
  }

  func missingCredentialLabels(in credentials: [String: String]) -> [String] {
    switch self {
    case .gitHubCopilot:
      let oauth = trimmedCredential(credentials[CredentialField.copilotOAuthToken])
      let pat = trimmedCredential(credentials[CredentialField.copilotPATToken])
      let username = trimmedCredential(credentials[CredentialField.copilotUsername])

      if !oauth.isEmpty || (!pat.isEmpty && !username.isEmpty) {
        return []
      }

      return ["OAuth token or PAT plus username"]
    default:
      return credentialFields
        .filter(\.isRequired)
        .filter { trimmedCredential(credentials[$0.key]).isEmpty }
        .map(\.label)
    }
  }

  func hasRequiredCredentials(_ credentials: [String: String]) -> Bool {
    missingCredentialLabels(in: credentials).isEmpty
  }
}

private func trimmedCredential(_ value: String?) -> String {
  value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

public enum QuotaErrorKind: String, Codable, Sendable {
  case notConfigured
  case auth
  case network
  case rateLimit
  case decoding
  case api
  case unknown
}

public struct UsageMetric: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public var label: String
  public var remainingPercent: Int?
  public var usedDisplay: String?
  public var totalDisplay: String?
  public var resetAt: Date?
  public var resetIn: String?
  public var isUnlimited: Bool
  public var detail: String?

  public init(
    id: String,
    label: String,
    remainingPercent: Int? = nil,
    usedDisplay: String? = nil,
    totalDisplay: String? = nil,
    resetAt: Date? = nil,
    resetIn: String? = nil,
    isUnlimited: Bool = false,
    detail: String? = nil
  ) {
    self.id = id
    self.label = label
    self.remainingPercent = remainingPercent
    self.usedDisplay = usedDisplay
    self.totalDisplay = totalDisplay
    self.resetAt = resetAt
    self.resetIn = resetIn
    self.isUnlimited = isUnlimited
    self.detail = detail
  }

  public var usageLine: String? {
    if isUnlimited {
      return "Unlimited"
    }

    guard let usedDisplay else {
      return nil
    }

    if let totalDisplay {
      return "\(usedDisplay) / \(totalDisplay)"
    }
    return usedDisplay
  }
}

public struct ProviderUsage: Codable, Hashable, Identifiable, Sendable {
  public var id: String { accountID }
  public var accountID: String
  public var provider: QuotaProvider
  public var title: String
  public var subtitle: String?
  public var metrics: [UsageMetric]
  public var maxUsagePercent: Int?
  public var warning: String?
  public var fetchedAt: Date

  public init(
    accountID: String? = nil,
    provider: QuotaProvider,
    title: String,
    subtitle: String? = nil,
    metrics: [UsageMetric],
    maxUsagePercent: Int? = nil,
    warning: String? = nil,
    fetchedAt: Date
  ) {
    self.accountID = accountID ?? provider.rawValue
    self.provider = provider
    self.title = title
    self.subtitle = subtitle
    self.metrics = metrics
    self.maxUsagePercent = maxUsagePercent
    self.warning = warning
    self.fetchedAt = fetchedAt
  }

  private enum CodingKeys: String, CodingKey {
    case accountID
    case provider
    case title
    case subtitle
    case metrics
    case maxUsagePercent
    case warning
    case fetchedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(QuotaProvider.self, forKey: .provider)
    accountID = (try? container.decodeIfPresent(String.self, forKey: .accountID)) ?? provider.rawValue
    title = try container.decode(String.self, forKey: .title)
    subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    metrics = try container.decode([UsageMetric].self, forKey: .metrics)
    maxUsagePercent = try container.decodeIfPresent(Int.self, forKey: .maxUsagePercent)
    warning = try container.decodeIfPresent(String.self, forKey: .warning)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountID, forKey: .accountID)
    try container.encode(provider, forKey: .provider)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(subtitle, forKey: .subtitle)
    try container.encode(metrics, forKey: .metrics)
    try container.encodeIfPresent(maxUsagePercent, forKey: .maxUsagePercent)
    try container.encodeIfPresent(warning, forKey: .warning)
    try container.encode(fetchedAt, forKey: .fetchedAt)
  }
}

public struct ProviderFailure: Codable, Hashable, Identifiable, Sendable {
  public var id: String { accountID }
  public var accountID: String
  public var provider: QuotaProvider
  public var kind: QuotaErrorKind
  public var message: String

  public init(accountID: String? = nil, provider: QuotaProvider, kind: QuotaErrorKind, message: String) {
    self.accountID = accountID ?? provider.rawValue
    self.provider = provider
    self.kind = kind
    self.message = message
  }

  private enum CodingKeys: String, CodingKey {
    case accountID
    case provider
    case kind
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(QuotaProvider.self, forKey: .provider)
    accountID = (try? container.decodeIfPresent(String.self, forKey: .accountID)) ?? provider.rawValue
    kind = try container.decode(QuotaErrorKind.self, forKey: .kind)
    message = try container.decode(String.self, forKey: .message)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountID, forKey: .accountID)
    try container.encode(provider, forKey: .provider)
    try container.encode(kind, forKey: .kind)
    try container.encode(message, forKey: .message)
  }
}

public struct QuotaSnapshot: Codable, Hashable, Sendable {
  public var version: Int
  public var generatedAt: Date
  public var providers: [ProviderUsage]
  public var failures: [ProviderFailure]

  public init(
    version: Int = 1,
    generatedAt: Date,
    providers: [ProviderUsage],
    failures: [ProviderFailure]
  ) {
    self.version = version
    self.generatedAt = generatedAt
    self.providers = providers
    self.failures = failures
  }

  public var isPartial: Bool { !failures.isEmpty }
}

public struct ProviderAccount: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var provider: QuotaProvider
  public var displayName: String
  public var isEnabled: Bool
  public var credentials: [String: String]

  public init(
    id: String = UUID().uuidString,
    provider: QuotaProvider,
    displayName: String? = nil,
    isEnabled: Bool = true,
    credentials: [String: String] = [:]
  ) {
    self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? UUID().uuidString : id
    self.provider = provider
    self.displayName = ProviderAccount.normalizedDisplayName(displayName, provider: provider)
    self.isEnabled = isEnabled
    self.credentials = credentials
  }

  public var resolvedDisplayName: String {
    ProviderAccount.normalizedDisplayName(displayName, provider: provider)
  }

  public var missingCredentialLabels: [String] {
    provider.missingCredentialLabels(in: credentials)
  }

  public var hasRequiredCredentials: Bool {
    missingCredentialLabels.isEmpty
  }

  public func redactedCredentials() -> ProviderAccount {
    ProviderAccount(
      id: id,
      provider: provider,
      displayName: displayName,
      isEnabled: isEnabled,
      credentials: [:]
    )
  }

  private static func normalizedDisplayName(_ value: String?, provider: QuotaProvider) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? provider.displayName : trimmed
  }
}

public enum WidgetBackgroundStyle: String, CaseIterable, Codable, Sendable {
  case system
  case graphite
  case ocean
  case forest
  case sunset

  public var displayName: String {
    switch self {
    case .system:
      return "Default"
    case .graphite:
      return "Graphite"
    case .ocean:
      return "Ocean"
    case .forest:
      return "Forest"
    case .sunset:
      return "Sunset"
    }
  }
}

public enum WidgetRingPalette: String, CaseIterable, Codable, Sendable {
  case traffic
  case cool
  case warm
  case monochrome

  public var displayName: String {
    switch self {
    case .traffic:
      return "Traffic Light"
    case .cool:
      return "Cool"
    case .warm:
      return "Warm"
    case .monochrome:
      return "Monochrome"
    }
  }
}

public enum WidgetRingColorRole: String, CaseIterable, Sendable {
  case high
  case medium
  case low
  case unlimited

  public var displayName: String {
    switch self {
    case .high:
      return "High (>=70%)"
    case .medium:
      return "Medium (40-69%)"
    case .low:
      return "Low (<40%)"
    case .unlimited:
      return "Unlimited"
    }
  }
}

// The inner layer survives only in stored settings (WidgetRingColors keeps
// both layers Codable); the UI edits the outer layer as the menu bar's
// status colors.
public enum WidgetRingLayer: String, CaseIterable, Sendable {
  case outer
  case inner
}

public struct WidgetRingColors: Codable, Hashable, Sendable {
  public var outerHighHexColor: String
  public var outerMediumHexColor: String
  public var outerLowHexColor: String
  public var outerUnlimitedHexColor: String
  public var innerHighHexColor: String
  public var innerMediumHexColor: String
  public var innerLowHexColor: String
  public var innerUnlimitedHexColor: String

  public init(
    outerHighHexColor: String = "#34C759",
    outerMediumHexColor: String = "#FFCC00",
    outerLowHexColor: String = "#FF3B30",
    outerUnlimitedHexColor: String = "#0A84FF",
    innerHighHexColor: String = "#34C759",
    innerMediumHexColor: String = "#FFCC00",
    innerLowHexColor: String = "#FF3B30",
    innerUnlimitedHexColor: String = "#0A84FF"
  ) {
    self.outerHighHexColor = normalizeHexColor(outerHighHexColor) ?? "#34C759"
    self.outerMediumHexColor = normalizeHexColor(outerMediumHexColor) ?? "#FFCC00"
    self.outerLowHexColor = normalizeHexColor(outerLowHexColor) ?? "#FF3B30"
    self.outerUnlimitedHexColor = normalizeHexColor(outerUnlimitedHexColor) ?? "#0A84FF"
    self.innerHighHexColor = normalizeHexColor(innerHighHexColor) ?? "#34C759"
    self.innerMediumHexColor = normalizeHexColor(innerMediumHexColor) ?? "#FFCC00"
    self.innerLowHexColor = normalizeHexColor(innerLowHexColor) ?? "#FF3B30"
    self.innerUnlimitedHexColor = normalizeHexColor(innerUnlimitedHexColor) ?? "#0A84FF"
  }

  public func hexColor(for role: WidgetRingColorRole, layer: WidgetRingLayer) -> String {
    switch (layer, role) {
    case (.outer, .high):
      return outerHighHexColor
    case (.outer, .medium):
      return outerMediumHexColor
    case (.outer, .low):
      return outerLowHexColor
    case (.outer, .unlimited):
      return outerUnlimitedHexColor
    case (.inner, .high):
      return innerHighHexColor
    case (.inner, .medium):
      return innerMediumHexColor
    case (.inner, .low):
      return innerLowHexColor
    case (.inner, .unlimited):
      return innerUnlimitedHexColor
    }
  }

  public mutating func setHexColor(_ value: String, for role: WidgetRingColorRole, layer: WidgetRingLayer) {
    guard let normalized = normalizeHexColor(value) else {
      return
    }

    switch (layer, role) {
    case (.outer, .high):
      outerHighHexColor = normalized
    case (.outer, .medium):
      outerMediumHexColor = normalized
    case (.outer, .low):
      outerLowHexColor = normalized
    case (.outer, .unlimited):
      outerUnlimitedHexColor = normalized
    case (.inner, .high):
      innerHighHexColor = normalized
    case (.inner, .medium):
      innerMediumHexColor = normalized
    case (.inner, .low):
      innerLowHexColor = normalized
    case (.inner, .unlimited):
      innerUnlimitedHexColor = normalized
    }
  }

  public static func defaults(for palette: WidgetRingPalette) -> WidgetRingColors {
    switch palette {
    case .traffic:
      return WidgetRingColors(
        outerHighHexColor: "#34C759",
        outerMediumHexColor: "#FFCC00",
        outerLowHexColor: "#FF3B30",
        outerUnlimitedHexColor: "#0A84FF",
        innerHighHexColor: "#34C759",
        innerMediumHexColor: "#FFCC00",
        innerLowHexColor: "#FF3B30",
        innerUnlimitedHexColor: "#0A84FF"
      )
    case .cool:
      return WidgetRingColors(
        outerHighHexColor: "#29D6F2",
        outerMediumHexColor: "#3394FA",
        outerLowHexColor: "#4D6BF9",
        outerUnlimitedHexColor: "#78CCFC",
        innerHighHexColor: "#29D6F2",
        innerMediumHexColor: "#3394FA",
        innerLowHexColor: "#4D6BF9",
        innerUnlimitedHexColor: "#78CCFC"
      )
    case .warm:
      return WidgetRingColors(
        outerHighHexColor: "#F5A847",
        outerMediumHexColor: "#F57D36",
        outerLowHexColor: "#F24F3D",
        outerUnlimitedHexColor: "#FAC45C",
        innerHighHexColor: "#F5A847",
        innerMediumHexColor: "#F57D36",
        innerLowHexColor: "#F24F3D",
        innerUnlimitedHexColor: "#FAC45C"
      )
    case .monochrome:
      return WidgetRingColors(
        outerHighHexColor: "#FFFFFFF2",
        outerMediumHexColor: "#FFFFFFBF",
        outerLowHexColor: "#FFFFFF8C",
        outerUnlimitedHexColor: "#FFFFFFE6",
        innerHighHexColor: "#FFFFFFF2",
        innerMediumHexColor: "#FFFFFFBF",
        innerLowHexColor: "#FFFFFF8C",
        innerUnlimitedHexColor: "#FFFFFFE6"
      )
    }
  }

  public static var `default`: WidgetRingColors {
    defaults(for: .traffic)
  }

  private enum CodingKeys: String, CodingKey {
    case outerHighHexColor
    case outerMediumHexColor
    case outerLowHexColor
    case outerUnlimitedHexColor
    case innerHighHexColor
    case innerMediumHexColor
    case innerLowHexColor
    case innerUnlimitedHexColor

    case highHexColor
    case mediumHexColor
    case lowHexColor
    case unlimitedHexColor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let defaults = WidgetRingColors.default
    let legacyHigh = (try? container.decodeIfPresent(String.self, forKey: .highHexColor)) ?? nil
    let legacyMedium = (try? container.decodeIfPresent(String.self, forKey: .mediumHexColor)) ?? nil
    let legacyLow = (try? container.decodeIfPresent(String.self, forKey: .lowHexColor)) ?? nil
    let legacyUnlimited = (try? container.decodeIfPresent(String.self, forKey: .unlimitedHexColor)) ?? nil

    let outerHigh = (try? container.decodeIfPresent(String.self, forKey: .outerHighHexColor)) ?? legacyHigh
    let outerMedium = (try? container.decodeIfPresent(String.self, forKey: .outerMediumHexColor)) ?? legacyMedium
    let outerLow = (try? container.decodeIfPresent(String.self, forKey: .outerLowHexColor)) ?? legacyLow
    let outerUnlimited = (try? container.decodeIfPresent(String.self, forKey: .outerUnlimitedHexColor)) ?? legacyUnlimited

    let innerHigh = (try? container.decodeIfPresent(String.self, forKey: .innerHighHexColor)) ?? legacyHigh
    let innerMedium = (try? container.decodeIfPresent(String.self, forKey: .innerMediumHexColor)) ?? legacyMedium
    let innerLow = (try? container.decodeIfPresent(String.self, forKey: .innerLowHexColor)) ?? legacyLow
    let innerUnlimited = (try? container.decodeIfPresent(String.self, forKey: .innerUnlimitedHexColor)) ?? legacyUnlimited

    outerHighHexColor = normalizeHexColor(outerHigh) ?? defaults.outerHighHexColor
    outerMediumHexColor = normalizeHexColor(outerMedium) ?? defaults.outerMediumHexColor
    outerLowHexColor = normalizeHexColor(outerLow) ?? defaults.outerLowHexColor
    outerUnlimitedHexColor = normalizeHexColor(outerUnlimited) ?? defaults.outerUnlimitedHexColor

    innerHighHexColor = normalizeHexColor(innerHigh) ?? defaults.innerHighHexColor
    innerMediumHexColor = normalizeHexColor(innerMedium) ?? defaults.innerMediumHexColor
    innerLowHexColor = normalizeHexColor(innerLow) ?? defaults.innerLowHexColor
    innerUnlimitedHexColor = normalizeHexColor(innerUnlimited) ?? defaults.innerUnlimitedHexColor
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(outerHighHexColor, forKey: .outerHighHexColor)
    try container.encode(outerMediumHexColor, forKey: .outerMediumHexColor)
    try container.encode(outerLowHexColor, forKey: .outerLowHexColor)
    try container.encode(outerUnlimitedHexColor, forKey: .outerUnlimitedHexColor)

    try container.encode(innerHighHexColor, forKey: .innerHighHexColor)
    try container.encode(innerMediumHexColor, forKey: .innerMediumHexColor)
    try container.encode(innerLowHexColor, forKey: .innerLowHexColor)
    try container.encode(innerUnlimitedHexColor, forKey: .innerUnlimitedHexColor)

    try container.encode(outerHighHexColor, forKey: .highHexColor)
    try container.encode(outerMediumHexColor, forKey: .mediumHexColor)
    try container.encode(outerLowHexColor, forKey: .lowHexColor)
    try container.encode(outerUnlimitedHexColor, forKey: .unlimitedHexColor)
  }

  var legacyPalette: WidgetRingPalette {
    if self == WidgetRingColors.defaults(for: .traffic) {
      return .traffic
    }
    if self == WidgetRingColors.defaults(for: .cool) {
      return .cool
    }
    if self == WidgetRingColors.defaults(for: .warm) {
      return .warm
    }
    if self == WidgetRingColors.defaults(for: .monochrome) {
      return .monochrome
    }
    return .traffic
  }
}

/// The reset-window family of a quota metric. Drives the metric's identity
/// color: one hue per kind across the dashboard, the widgets, and the trend
/// chart, so "weekly" always looks the same regardless of account.
public enum QuotaWindowKind: String, Codable, CaseIterable, Sendable {
  case session
  case daily
  case weekly
  case monthly
  case other

  public var displayName: String {
    switch self {
    case .session:
      return "Session (hours)"
    case .daily:
      return "Daily"
    case .weekly:
      return "Weekly"
    case .monthly:
      return "Monthly"
    case .other:
      return "Other"
    }
  }

  /// Providers never report the window length as data, only in ids and labels
  /// ("5-hour limit", "seven_day", "MCP monthly quota"), so classification
  /// parses both. Metrics with no window wording at all (e.g. Google's
  /// per-model quotas) land in `.other` and take stable auxiliary colors by
  /// their position among the account's other-kind metrics.
  public static func classify(metricID: String, label: String) -> QuotaWindowKind {
    // GitHub Copilot's premium-request pool resets monthly; nothing in the
    // metric text says so.
    if metricID.lowercased() == "premium" {
      return .monthly
    }

    let haystack = "\(metricID) \(label)".lowercased()
    let tokens = haystack
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)

    if let hours = leadingCount(beforeUnit: "hour", in: tokens) {
      return hours >= 20 ? .daily : .session
    }

    if let days = leadingCount(beforeUnit: "day", in: tokens) {
      if days <= 1 {
        return .daily
      }
      return days <= 13 ? .weekly : .monthly
    }

    if haystack.contains("month") {
      return .monthly
    }
    if haystack.contains("week") {
      return .weekly
    }
    if haystack.contains("hour") || haystack.contains("session") {
      return .session
    }
    if haystack.contains("daily") {
      return .daily
    }

    return .other
  }

  private static func leadingCount(beforeUnit unit: String, in tokens: [String]) -> Int? {
    let plural = unit + "s"
    for (index, token) in tokens.enumerated() where token == unit || token == plural {
      guard index > 0, let count = Int(tokens[index - 1]) else {
        continue
      }
      return count
    }
    return nil
  }
}

/// One identity color per limit-window kind. Values are validated categorical
/// colors (CVD-separated, chroma >= 0.10, >= 3:1 on the dashboard graphite);
/// chart lines, sparklines, bars, and rings all resolve through this table.
public struct LimitKindColors: Codable, Hashable, Sendable {
  public var sessionHexColor: String
  public var dailyHexColor: String
  public var weeklyHexColor: String
  public var monthlyHexColor: String
  public var otherHexColors: [String]
  public var unlimitedHexColor: String

  public static let defaultSessionHexColor = "#3ED8F0"
  public static let defaultDailyHexColor = "#2ECC6E"
  public static let defaultWeeklyHexColor = "#FFC145"
  public static let defaultMonthlyHexColor = "#FF8ED6"
  public static let defaultOtherHexColors = ["#B8A8FF", "#F2734D"]
  public static let defaultUnlimitedHexColor = "#C2E5FF"

  public init(
    sessionHexColor: String = LimitKindColors.defaultSessionHexColor,
    dailyHexColor: String = LimitKindColors.defaultDailyHexColor,
    weeklyHexColor: String = LimitKindColors.defaultWeeklyHexColor,
    monthlyHexColor: String = LimitKindColors.defaultMonthlyHexColor,
    otherHexColors: [String] = LimitKindColors.defaultOtherHexColors,
    unlimitedHexColor: String = LimitKindColors.defaultUnlimitedHexColor
  ) {
    self.sessionHexColor = normalizeHexColor(sessionHexColor) ?? Self.defaultSessionHexColor
    self.dailyHexColor = normalizeHexColor(dailyHexColor) ?? Self.defaultDailyHexColor
    self.weeklyHexColor = normalizeHexColor(weeklyHexColor) ?? Self.defaultWeeklyHexColor
    self.monthlyHexColor = normalizeHexColor(monthlyHexColor) ?? Self.defaultMonthlyHexColor
    let normalizedOthers = otherHexColors.compactMap { normalizeHexColor($0) }
    self.otherHexColors = normalizedOthers.isEmpty ? Self.defaultOtherHexColors : normalizedOthers
    self.unlimitedHexColor = normalizeHexColor(unlimitedHexColor) ?? Self.defaultUnlimitedHexColor
  }

  /// `otherSlot` picks the auxiliary color for `.other` metrics (cycling when
  /// an account has more of them than the table has colors) and is ignored for
  /// classified kinds.
  public func hexColor(for kind: QuotaWindowKind, otherSlot: Int = 0) -> String {
    switch kind {
    case .session:
      return sessionHexColor
    case .daily:
      return dailyHexColor
    case .weekly:
      return weeklyHexColor
    case .monthly:
      return monthlyHexColor
    case .other:
      guard !otherHexColors.isEmpty else {
        return Self.defaultOtherHexColors[0]
      }
      return otherHexColors[max(0, otherSlot) % otherHexColors.count]
    }
  }

  public mutating func setHexColor(_ value: String, for kind: QuotaWindowKind, otherSlot: Int = 0) {
    guard let normalized = normalizeHexColor(value) else {
      return
    }

    switch kind {
    case .session:
      sessionHexColor = normalized
    case .daily:
      dailyHexColor = normalized
    case .weekly:
      weeklyHexColor = normalized
    case .monthly:
      monthlyHexColor = normalized
    case .other:
      guard !otherHexColors.isEmpty else {
        otherHexColors = [normalized]
        return
      }
      otherHexColors[max(0, otherSlot) % otherHexColors.count] = normalized
    }
  }

  public static var `default`: LimitKindColors {
    LimitKindColors()
  }

  private enum CodingKeys: String, CodingKey {
    case sessionHexColor
    case dailyHexColor
    case weeklyHexColor
    case monthlyHexColor
    case otherHexColors
    case unlimitedHexColor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      sessionHexColor: (try? container.decodeIfPresent(String.self, forKey: .sessionHexColor)) ?? Self.defaultSessionHexColor,
      dailyHexColor: (try? container.decodeIfPresent(String.self, forKey: .dailyHexColor)) ?? Self.defaultDailyHexColor,
      weeklyHexColor: (try? container.decodeIfPresent(String.self, forKey: .weeklyHexColor)) ?? Self.defaultWeeklyHexColor,
      monthlyHexColor: (try? container.decodeIfPresent(String.self, forKey: .monthlyHexColor)) ?? Self.defaultMonthlyHexColor,
      otherHexColors: (try? container.decodeIfPresent([String].self, forKey: .otherHexColors)) ?? Self.defaultOtherHexColors,
      unlimitedHexColor: (try? container.decodeIfPresent(String.self, forKey: .unlimitedHexColor)) ?? Self.defaultUnlimitedHexColor
    )
  }
}

public struct WidgetStyleSettings: Codable, Hashable, Sendable {
  public var backgroundHexColor: String?
  public var ringColors: WidgetRingColors
  public var limitKindColors: LimitKindColors
  public var useTransparentBackground: Bool

  public init(
    backgroundHexColor: String? = nil,
    ringColors: WidgetRingColors = .default,
    limitKindColors: LimitKindColors = .default,
    useTransparentBackground: Bool = false
  ) {
    self.backgroundHexColor = normalizeHexColor(backgroundHexColor)
    self.ringColors = ringColors
    self.limitKindColors = limitKindColors
    self.useTransparentBackground = useTransparentBackground
  }

  private enum CodingKeys: String, CodingKey {
    case backgroundHexColor
    case ringColors
    case limitKindColors
    case useTransparentBackground
    case showBackground
    case backgroundStyle
    case ringPalette
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacyShowBackground = try? container.decodeIfPresent(Bool.self, forKey: .showBackground)

    let decodedBackground = (try? container.decodeIfPresent(String.self, forKey: .backgroundHexColor)) ?? nil
    let decodedBackgroundHex = normalizeHexColor(decodedBackground)
    if let decodedBackgroundHex {
      backgroundHexColor = decodedBackgroundHex
    } else {
      let decodedStyle = (try? container.decodeIfPresent(WidgetBackgroundStyle.self, forKey: .backgroundStyle)) ?? .system
      let resolvedStyle = (legacyShowBackground == false) ? WidgetBackgroundStyle.system : decodedStyle
      backgroundHexColor = resolvedStyle.defaultBackgroundHexColor
    }

    if let decodedRingColors = (try? container.decodeIfPresent(WidgetRingColors.self, forKey: .ringColors)) ?? nil {
      ringColors = decodedRingColors
    } else {
      let legacyPalette = (try? container.decodeIfPresent(WidgetRingPalette.self, forKey: .ringPalette)) ?? .traffic
      ringColors = WidgetRingColors.defaults(for: legacyPalette)
    }

    limitKindColors = (try? container.decodeIfPresent(LimitKindColors.self, forKey: .limitKindColors)) ?? .default
    useTransparentBackground = (try? container.decodeIfPresent(Bool.self, forKey: .useTransparentBackground)) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encodeIfPresent(backgroundHexColor, forKey: .backgroundHexColor)
    try container.encode(ringColors, forKey: .ringColors)
    try container.encode(limitKindColors, forKey: .limitKindColors)
    try container.encode(useTransparentBackground, forKey: .useTransparentBackground)

    try container.encode(!useTransparentBackground && backgroundHexColor != nil, forKey: .showBackground)
    try container.encode(
      WidgetBackgroundStyle.legacyStyle(for: useTransparentBackground ? nil : backgroundHexColor),
      forKey: .backgroundStyle
    )
    try container.encode(ringColors.legacyPalette, forKey: .ringPalette)
  }

  public static var `default`: WidgetStyleSettings {
    WidgetStyleSettings()
  }
}

private extension WidgetBackgroundStyle {
  var defaultBackgroundHexColor: String? {
    switch self {
    case .system:
      return nil
    case .graphite:
      return "#475270"
    case .ocean:
      return "#1F9EFA"
    case .forest:
      return "#1FBD61"
    case .sunset:
      return "#FA7833"
    }
  }

  static func legacyStyle(for backgroundHexColor: String?) -> WidgetBackgroundStyle {
    guard let normalized = normalizeHexColor(backgroundHexColor) else {
      return .system
    }

    if normalized == WidgetBackgroundStyle.graphite.defaultBackgroundHexColor {
      return .graphite
    }
    if normalized == WidgetBackgroundStyle.ocean.defaultBackgroundHexColor {
      return .ocean
    }
    if normalized == WidgetBackgroundStyle.forest.defaultBackgroundHexColor {
      return .forest
    }
    if normalized == WidgetBackgroundStyle.sunset.defaultBackgroundHexColor {
      return .sunset
    }

    return .graphite
  }
}

private func normalizeHexColor(_ value: String?) -> String? {
  guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
    return nil
  }

  if raw.hasPrefix("#") {
    raw.removeFirst()
  }

  if raw.count == 3 || raw.count == 4 {
    raw = raw.map { "\($0)\($0)" }.joined()
  }

  guard raw.count == 6 || raw.count == 8 else {
    return nil
  }

  guard raw.allSatisfy({ $0.isHexDigit }) else {
    return nil
  }

  return "#\(raw.uppercased())"
}

public struct ProviderStyleSettings: Codable, Hashable, Sendable {
  public var accountID: String
  public var provider: QuotaProvider?
  public var useCustomStyle: Bool
  public var style: WidgetStyleSettings

  public init(
    accountID: String,
    provider: QuotaProvider? = nil,
    useCustomStyle: Bool = false,
    style: WidgetStyleSettings = .default
  ) {
    self.accountID = accountID
    self.provider = provider
    self.useCustomStyle = useCustomStyle
    self.style = style
  }

  public static func defaultValue(
    for accountID: String,
    provider: QuotaProvider? = nil,
    fallbackStyle: WidgetStyleSettings = .default
  ) -> ProviderStyleSettings {
    ProviderStyleSettings(accountID: accountID, provider: provider, useCustomStyle: false, style: fallbackStyle)
  }

  private enum CodingKeys: String, CodingKey {
    case accountID
    case provider
    case useCustomStyle
    case style
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try? container.decodeIfPresent(QuotaProvider.self, forKey: .provider)
    accountID = (try? container.decodeIfPresent(String.self, forKey: .accountID))
      ?? provider?.rawValue
      ?? UUID().uuidString
    useCustomStyle = (try? container.decodeIfPresent(Bool.self, forKey: .useCustomStyle)) ?? false
    style = (try? container.decodeIfPresent(WidgetStyleSettings.self, forKey: .style)) ?? .default
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountID, forKey: .accountID)
    try container.encodeIfPresent(provider, forKey: .provider)
    try container.encode(useCustomStyle, forKey: .useCustomStyle)
    try container.encode(style, forKey: .style)
  }
}

public struct WidgetBackgroundOverride: Codable, Hashable, Sendable {
  public var useCustomBackground: Bool
  public var backgroundHexColor: String?
  public var useTransparentBackground: Bool

  public init(
    useCustomBackground: Bool = false,
    backgroundHexColor: String? = nil,
    useTransparentBackground: Bool = false
  ) {
    self.useCustomBackground = useCustomBackground
    self.backgroundHexColor = normalizeHexColor(backgroundHexColor)
    self.useTransparentBackground = useTransparentBackground
  }

  private enum CodingKeys: String, CodingKey {
    case useCustomBackground
    case backgroundHexColor
    case useTransparentBackground
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    useCustomBackground = (try? container.decodeIfPresent(Bool.self, forKey: .useCustomBackground)) ?? false
    let decodedBackground = (try? container.decodeIfPresent(String.self, forKey: .backgroundHexColor)) ?? nil
    backgroundHexColor = normalizeHexColor(decodedBackground)
    useTransparentBackground = (try? container.decodeIfPresent(Bool.self, forKey: .useTransparentBackground)) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(useCustomBackground, forKey: .useCustomBackground)
    try container.encodeIfPresent(backgroundHexColor, forKey: .backgroundHexColor)
    try container.encode(useTransparentBackground, forKey: .useTransparentBackground)
  }

  public static var `default`: WidgetBackgroundOverride {
    WidgetBackgroundOverride()
  }
}

public struct WidgetBackgroundSettings: Codable, Hashable, Sendable {
  public var dashboard: WidgetBackgroundOverride
  public var trend: WidgetBackgroundOverride

  public init(
    dashboard: WidgetBackgroundOverride = .default,
    trend: WidgetBackgroundOverride = .default
  ) {
    self.dashboard = dashboard
    self.trend = trend
  }

  private enum CodingKeys: String, CodingKey {
    case dashboard
    case trend
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dashboard = (try? container.decodeIfPresent(WidgetBackgroundOverride.self, forKey: .dashboard)) ?? .default
    trend = (try? container.decodeIfPresent(WidgetBackgroundOverride.self, forKey: .trend)) ?? .default
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(dashboard, forKey: .dashboard)
    try container.encode(trend, forKey: .trend)
  }

  public static var `default`: WidgetBackgroundSettings {
    WidgetBackgroundSettings()
  }
}

public struct WidgetVisibilitySettings: Codable, Hashable, Sendable {
  public var showTimestamp: Bool
  public var showFailureCount: Bool
  public var showResetInfo: Bool
  public var showOverviewMetricSummary: Bool
  public var showPercentageValues: Bool
  public var showDualLimitPercentagesInDashboard: Bool
  public var showMediumProgressBars: Bool
  public var smallDashboardProviderLimit: Int
  public var mediumProviderLimit: Int
  public var trendHistoryDays: Int

  public init(
    showTimestamp: Bool = true,
    showFailureCount: Bool = true,
    showResetInfo: Bool = true,
    showOverviewMetricSummary: Bool = true,
    showPercentageValues: Bool = true,
    showDualLimitPercentagesInDashboard: Bool = true,
    showMediumProgressBars: Bool = true,
    smallDashboardProviderLimit: Int = 2,
    mediumProviderLimit: Int = 6,
    trendHistoryDays: Int = 7
  ) {
    self.showTimestamp = showTimestamp
    self.showFailureCount = showFailureCount
    self.showResetInfo = showResetInfo
    self.showOverviewMetricSummary = showOverviewMetricSummary
    self.showPercentageValues = showPercentageValues
    self.showDualLimitPercentagesInDashboard = showDualLimitPercentagesInDashboard
    self.showMediumProgressBars = showMediumProgressBars
    self.smallDashboardProviderLimit = Self.clampSmallProviderLimit(smallDashboardProviderLimit)
    self.mediumProviderLimit = Self.clampMediumProviderLimit(mediumProviderLimit)
    self.trendHistoryDays = Self.clampTrendHistoryDays(trendHistoryDays)
  }

  public static var `default`: WidgetVisibilitySettings {
    WidgetVisibilitySettings()
  }

  private enum CodingKeys: String, CodingKey {
    case showTimestamp
    case showFailureCount
    case showResetInfo
    case showOverviewMetricSummary
    case showPercentageValues
    case showDualLimitPercentagesInDashboard
    case showMediumProgressBars
    case smallDashboardProviderLimit
    case mediumProviderLimit
    case trendHistoryDays
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    showTimestamp = (try? container.decodeIfPresent(Bool.self, forKey: .showTimestamp)) ?? true
    showFailureCount = (try? container.decodeIfPresent(Bool.self, forKey: .showFailureCount)) ?? true
    showResetInfo = (try? container.decodeIfPresent(Bool.self, forKey: .showResetInfo)) ?? true
    showOverviewMetricSummary = (try? container.decodeIfPresent(Bool.self, forKey: .showOverviewMetricSummary)) ?? true
    showPercentageValues = (try? container.decodeIfPresent(Bool.self, forKey: .showPercentageValues)) ?? true
    showDualLimitPercentagesInDashboard = (try? container.decodeIfPresent(Bool.self, forKey: .showDualLimitPercentagesInDashboard)) ?? true
    showMediumProgressBars = (try? container.decodeIfPresent(Bool.self, forKey: .showMediumProgressBars)) ?? true
    let decodedSmallProviderLimit = (try? container.decodeIfPresent(Int.self, forKey: .smallDashboardProviderLimit)) ?? 2
    smallDashboardProviderLimit = Self.clampSmallProviderLimit(decodedSmallProviderLimit)
    let decodedProviderLimit = (try? container.decodeIfPresent(Int.self, forKey: .mediumProviderLimit)) ?? 6
    mediumProviderLimit = Self.clampMediumProviderLimit(decodedProviderLimit)
    let decodedTrendDays = (try? container.decodeIfPresent(Int.self, forKey: .trendHistoryDays)) ?? 7
    trendHistoryDays = Self.clampTrendHistoryDays(decodedTrendDays)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(showTimestamp, forKey: .showTimestamp)
    try container.encode(showFailureCount, forKey: .showFailureCount)
    try container.encode(showResetInfo, forKey: .showResetInfo)
    try container.encode(showOverviewMetricSummary, forKey: .showOverviewMetricSummary)
    try container.encode(showPercentageValues, forKey: .showPercentageValues)
    try container.encode(showDualLimitPercentagesInDashboard, forKey: .showDualLimitPercentagesInDashboard)
    try container.encode(showMediumProgressBars, forKey: .showMediumProgressBars)
    try container.encode(Self.clampSmallProviderLimit(smallDashboardProviderLimit), forKey: .smallDashboardProviderLimit)
    try container.encode(Self.clampMediumProviderLimit(mediumProviderLimit), forKey: .mediumProviderLimit)
    try container.encode(Self.clampTrendHistoryDays(trendHistoryDays), forKey: .trendHistoryDays)
  }

  private static func clampSmallProviderLimit(_ value: Int) -> Int {
    max(1, min(4, value))
  }

  private static func clampMediumProviderLimit(_ value: Int) -> Int {
    max(1, min(12, value))
  }

  private static func clampTrendHistoryDays(_ value: Int) -> Int {
    max(1, min(30, value))
  }
}

public struct AppSettings: Codable, Hashable, Sendable {
  public static let refreshIntervalRange = 15...180
  /// Number of independently placeable "Provider Tile" widgets. WidgetKit requires
  /// one compile-time widget kind per tile, so this cannot be dynamic; changing it
  /// means adding/removing ProviderTileSlotNWidget types in the widget bundle too.
  public static let providerTileSlotCount = 8

  public var refreshIntervalMinutes: Int
  public var accounts: [ProviderAccount]
  public var widgetStyle: WidgetStyleSettings
  public var widgetBackgroundSettings: WidgetBackgroundSettings
  public var providerStyleSettings: [ProviderStyleSettings]
  public var widgetVisibility: WidgetVisibilitySettings
  /// Account ID per provider-tile slot; "" means automatic (first enabled account).
  /// Always normalized to exactly `providerTileSlotCount` entries.
  public var providerTileSlots: [String]

  public init(
    refreshIntervalMinutes: Int = 30,
    accounts: [ProviderAccount] = [],
    widgetStyle: WidgetStyleSettings = .default,
    widgetBackgroundSettings: WidgetBackgroundSettings = .default,
    providerStyleSettings: [ProviderStyleSettings] = [],
    widgetVisibility: WidgetVisibilitySettings = .default,
    providerTileSlots: [String] = []
  ) {
    self.refreshIntervalMinutes = AppSettings.clampedRefreshInterval(refreshIntervalMinutes)
    self.accounts = AppSettings.normalizedAccounts(accounts)
    self.widgetStyle = widgetStyle
    self.widgetBackgroundSettings = widgetBackgroundSettings
    self.providerStyleSettings = AppSettings.normalizedProviderStyleSettings(providerStyleSettings, accounts: self.accounts)
    self.widgetVisibility = widgetVisibility
    self.providerTileSlots = AppSettings.normalizedProviderTileSlots(providerTileSlots)
  }

  public static var `default`: AppSettings {
    AppSettings(
      refreshIntervalMinutes: 30,
      accounts: [],
      widgetStyle: .default,
      widgetBackgroundSettings: .default,
      providerStyleSettings: [],
      widgetVisibility: .default
    )
  }

  public func account(withID accountID: String) -> ProviderAccount? {
    accounts.first(where: { $0.id == accountID })
  }

  public func styleOverride(for accountID: String) -> ProviderStyleSettings {
    if let existing = providerStyleSettings.first(where: { $0.accountID == accountID }) {
      return existing
    }

    return ProviderStyleSettings.defaultValue(
      for: accountID,
      provider: account(withID: accountID)?.provider,
      fallbackStyle: widgetStyle
    )
  }

  /// The account ID assigned to a provider-tile slot, or nil for automatic.
  public func providerTileAssignment(forSlot index: Int) -> String? {
    guard providerTileSlots.indices.contains(index) else { return nil }
    let value = providerTileSlots[index].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Stable order backing automatic tile assignment. The app's Settings UI and
  /// the widget extension must agree on this order, which is why it lives here.
  public var providerTileAutoOrder: [ProviderAccount] {
    stableAccountOrder(accounts.filter(\.isEnabled))
  }

  /// Enabled accounts not explicitly pinned to any slot, in stable order.
  /// Unassigned slots draw from this list so an auto tile never duplicates a
  /// pinned tile: the K-th unassigned slot shows element K.
  public func providerTileAutoCandidates() -> [ProviderAccount] {
    let assigned = Set(
      providerTileSlots
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    return providerTileAutoOrder.filter { !assigned.contains($0.id) }
  }

  /// Position of an unassigned slot among all unassigned slots (0-based), or
  /// nil when the slot has an explicit assignment. Indexes
  /// `providerTileAutoCandidates()`.
  public func providerTileAutoRank(forSlot index: Int) -> Int? {
    guard index >= 0, index < AppSettings.providerTileSlotCount else { return nil }
    guard providerTileAssignment(forSlot: index) == nil else { return nil }
    return (0..<index).filter { providerTileAssignment(forSlot: $0) == nil }.count
  }

  public func redactedCredentials() -> AppSettings {
    AppSettings(
      refreshIntervalMinutes: refreshIntervalMinutes,
      accounts: accounts.map { $0.redactedCredentials() },
      widgetStyle: widgetStyle,
      widgetBackgroundSettings: widgetBackgroundSettings,
      providerStyleSettings: providerStyleSettings,
      widgetVisibility: widgetVisibility,
      providerTileSlots: providerTileSlots
    )
  }

  private enum CodingKeys: String, CodingKey {
    case refreshIntervalMinutes
    case accounts
    case widgetStyle
    case widgetBackgroundSettings
    case providerStyleSettings
    case widgetVisibility
    case providerTileSlots
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let decodedRefreshInterval = (try? container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)) ?? 30
    refreshIntervalMinutes = AppSettings.clampedRefreshInterval(decodedRefreshInterval)

    accounts = AppSettings.normalizedAccounts(
      try container.decodeIfPresent([ProviderAccount].self, forKey: .accounts) ?? []
    )

    widgetStyle = (try? container.decodeIfPresent(WidgetStyleSettings.self, forKey: .widgetStyle)) ?? .default
    widgetBackgroundSettings = (try? container.decodeIfPresent(
      WidgetBackgroundSettings.self,
      forKey: .widgetBackgroundSettings
    )) ?? .default

    let decodedStyleSettings = (try? container.decodeIfPresent(
      [ProviderStyleSettings].self,
      forKey: .providerStyleSettings
    )) ?? []
    providerStyleSettings = AppSettings.normalizedProviderStyleSettings(
      decodedStyleSettings,
      accounts: accounts
    )

    widgetVisibility = (try? container.decodeIfPresent(WidgetVisibilitySettings.self, forKey: .widgetVisibility)) ?? .default

    providerTileSlots = AppSettings.normalizedProviderTileSlots(
      (try? container.decodeIfPresent([String].self, forKey: .providerTileSlots)) ?? []
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(AppSettings.clampedRefreshInterval(refreshIntervalMinutes), forKey: .refreshIntervalMinutes)
    try container.encode(accounts, forKey: .accounts)
    try container.encode(widgetStyle, forKey: .widgetStyle)
    try container.encode(widgetBackgroundSettings, forKey: .widgetBackgroundSettings)
    try container.encode(providerStyleSettings, forKey: .providerStyleSettings)
    try container.encode(widgetVisibility, forKey: .widgetVisibility)
    try container.encode(AppSettings.normalizedProviderTileSlots(providerTileSlots), forKey: .providerTileSlots)
  }

  private static func normalizedAccounts(_ values: [ProviderAccount]) -> [ProviderAccount] {
    var seen: Set<String> = []
    return values.map { account in
      var normalized = account
      if normalized.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || seen.contains(normalized.id) {
        normalized.id = UUID().uuidString
      }
      normalized.displayName = normalized.resolvedDisplayName
      seen.insert(normalized.id)
      return normalized
    }
  }

  private static func clampedRefreshInterval(_ value: Int) -> Int {
    min(max(value, refreshIntervalRange.lowerBound), refreshIntervalRange.upperBound)
  }

  private static func normalizedProviderTileSlots(_ values: [String]) -> [String] {
    var slots = values.prefix(providerTileSlotCount).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while slots.count < providerTileSlotCount {
      slots.append("")
    }
    return Array(slots)
  }

  private static func normalizedProviderStyleSettings(
    _ values: [ProviderStyleSettings],
    accounts: [ProviderAccount]
  ) -> [ProviderStyleSettings] {
    accounts.map { account in
      if var existing = values.first(where: { $0.accountID == account.id }) {
        existing.provider = account.provider
        return existing
      }

      if var legacy = values.first(where: { $0.accountID == account.provider.rawValue || $0.provider == account.provider }) {
        legacy.accountID = account.id
        legacy.provider = account.provider
        return legacy
      }

      return ProviderStyleSettings.defaultValue(for: account.id, provider: account.provider)
    }
  }
}

public struct ProviderRuntimeConfiguration: Hashable, Sendable {
  public var accountID: String
  public var provider: QuotaProvider
  public var displayName: String
  public var isEnabled: Bool
  public var credentials: [String: String]

  public init(
    accountID: String? = nil,
    provider: QuotaProvider,
    displayName: String? = nil,
    isEnabled: Bool,
    credentials: [String: String]
  ) {
    self.accountID = accountID ?? provider.rawValue
    self.provider = provider
    self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? displayName!
      : provider.displayName
    self.isEnabled = isEnabled
    self.credentials = credentials
  }
}
