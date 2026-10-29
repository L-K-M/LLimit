import Foundation

/// Product and account context for choosing a provider, independent of stored IDs.
public struct ProviderCatalogEntry: Identifiable, Equatable, Sendable {
  public var id: QuotaProvider { provider }
  public let provider: QuotaProvider
  public let title: String
  public let context: String
  public let summary: String
  fileprivate let aliases: [String]

  fileprivate func matches(_ query: String, additionalTerms: [String] = []) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace).map { Self.normalized(String($0)) }
      .filter { !$0.isEmpty }
    let text = Self.normalized(([title, context, provider.displayName, provider.rawValue] + aliases + additionalTerms).joined(separator: " "))
    return words.allSatisfy { text.contains($0) }
  }

  private static func normalized(_ value: String) -> String {
    let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
    return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) })
  }
}

public enum ProviderCatalog {
  public static let entries: [ProviderCatalogEntry] = QuotaProvider.allCases.map(entry(for:))
    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

  public static func search(_ query: String) -> [ProviderCatalogEntry] {
    entries.filter { $0.matches(query) }
  }

  /// Search display metadata only. Authentication values never participate.
  public static func search(_ query: String, credentials: [DiscoveredCredential]) -> [DiscoveredCredential] {
    credentials.filter { entry(for: $0.provider).matches(query, additionalTerms: [$0.suggestedName, $0.sourceLabel]) }
  }

  public static func entry(for provider: QuotaProvider) -> ProviderCatalogEntry {
    switch provider {
    case .anthropic:
      return ProviderCatalogEntry(provider: provider, title: "Claude", context: "Anthropic · Claude & Claude Code",
        summary: "Track usage from your Claude subscription, including Claude Code.", aliases: [])
    case .openAI:
      return ProviderCatalogEntry(provider: provider, title: "ChatGPT & Codex", context: "OpenAI · ChatGPT plans",
        summary: "Track Codex usage included with your ChatGPT subscription. OpenAI API billing is separate.", aliases: [])
    case .gitHubCopilot:
      return ProviderCatalogEntry(provider: provider, title: "Copilot", context: "GitHub · Premium requests",
        summary: "Track the premium-request allowance for your GitHub Copilot plan.", aliases: [])
    case .zhipu:
      return ProviderCatalogEntry(provider: provider, title: "Zhipu AI / BigModel", context: "GLM Coding Plan · China",
        summary: "For a GLM Coding Plan bought at bigmodel.cn. Z.ai is the international platform and uses a separate account and key.",
        aliases: ["智谱", "bigmodel.cn", "mainland", "domestic"])
    case .zai:
      return ProviderCatalogEntry(provider: provider, title: "Z.ai", context: "GLM Coding Plan · International",
        summary: "For a GLM Coding Plan bought at z.ai. The China platform, Zhipu AI / BigModel, uses a separate account and key.",
        aliases: ["global", "zai"])
    case .kimi:
      return ProviderCatalogEntry(provider: provider, title: "Kimi Code", context: "Moonshot AI · Coding subscription",
        summary: "Track your Kimi for Coding subscription. Use a Kimi Code account, rather than a Moonshot API billing account.", aliases: [])
    case .googleAntigravity:
      return ProviderCatalogEntry(provider: provider, title: "Antigravity", context: "Google · Model quotas",
        summary: "Track the remaining per-model quotas for your Google Antigravity account.", aliases: [])
    case .devin:
      return ProviderCatalogEntry(provider: provider, title: "Devin CLI", context: "Cognition · CLI subscription",
        summary: "Track your Devin CLI subscription quota. This connection does not report Devin Cloud credit usage.", aliases: [])
    case .metaMuse:
      return ProviderCatalogEntry(provider: provider, title: "Muse Code", context: "Meta · Subscription usage",
        summary: "Track the current and weekly usage windows of your Muse Code subscription.", aliases: [])
    case .openCodeGo:
      return ProviderCatalogEntry(provider: provider, title: "OpenCode Go", context: "OpenCode · Go subscription",
        summary: "Track the rolling, weekly, and monthly limits of an OpenCode Go subscription. A Zen-only account does not include Go.", aliases: [])
    case .venice:
      return ProviderCatalogEntry(provider: provider, title: "Venice", context: "Venice · DIEM and credits",
        summary: "Track daily DIEM and available credit balances for your Venice account.", aliases: [])
    case .cline:
      return ProviderCatalogEntry(provider: provider, title: "Cline", context: "Cline · ClinePass and credits",
        summary: "Track ClinePass subscription limits and your prepaid Cline credit balance.", aliases: [])
    case .junie:
      return ProviderCatalogEntry(provider: provider, title: "Junie", context: "JetBrains · AI credits",
        summary: "Track the JetBrains AI credit balance used by Junie. You can configure your plan allowance and reset date.", aliases: [])
    case .minimax:
      return ProviderCatalogEntry(provider: provider, title: "MiniMax", context: "M Plan · Global",
        summary: "Track a global MiniMax M Plan subscription using its Subscription Key from minimax.io.", aliases: ["international"])
    case .xiaomiMiMo:
      return ProviderCatalogEntry(provider: provider, title: "MiMo", context: "Xiaomi · Personal Token Plan",
        summary: "Track a personal MiMo Token Plan on the Xiaomi MiMo API Platform. Team plans and Desktop memberships are separate.", aliases: [])
    case .stepFun:
      return ProviderCatalogEntry(provider: provider, title: "StepFun", context: "Step Plan · Global",
        summary: "Track your personal Step Plan and any top-up credits on the global StepFun platform.", aliases: ["international"])
    case .mistral:
      return ProviderCatalogEntry(provider: provider, title: "Mistral", context: "Mistral · Vibe Code and API allowance",
        summary: "Track the included monthly Vibe Code and API allowances shown in your Mistral subscription.",
        aliases: ["Le Chat", "Pro", "Team"])
    }
  }
}
