import XCTest
@testable import QuotaCore

final class ProviderCatalogTests: XCTestCase {
  private func providers(matching query: String) -> [QuotaProvider] {
    ProviderCatalog.search(query).map(\.provider)
  }

  func testCatalogIncludesEveryProviderExactlyOnceWithConsistentIdentity() {
    let entries = ProviderCatalog.entries
    XCTAssertEqual(entries.count, QuotaProvider.allCases.count)
    XCTAssertEqual(Set(entries.map(\.provider)), Set(QuotaProvider.allCases))
    XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    for entry in entries {
      XCTAssertEqual(entry.id, entry.provider)
      XCTAssertEqual(ProviderCatalog.entry(for: entry.provider), entry)
      XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertFalse(entry.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertFalse(entry.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    // Renaming chooser copy must not rename persisted account/provider IDs.
    for (provider, persistedID) in [(QuotaProvider.openAI, "openai"), (.devin, "devin"),
                                    (.zhipu, "zhipu"), (.zai, "zai")] {
      XCTAssertEqual(ProviderCatalog.entry(for: provider).id.rawValue, persistedID)
    }
  }

  func testCatalogIsAlphabeticalByVisibleTitle() {
    let titles = ProviderCatalog.entries.map { $0.title.lowercased() }
    XCTAssertEqual(titles, titles.sorted())
    XCTAssertEqual(ProviderCatalog.entries.first?.provider, .googleAntigravity)
    XCTAssertEqual(ProviderCatalog.entries.last?.provider, .zhipu)
  }

  func testOpenAICompanyAndProductNamesFindTheSameConnection() {
    for query in ["OpenAI", "ChatGPT", "Codex"] {
      XCTAssertEqual(providers(matching: query), [.openAI], "Query: \(query)")
    }
  }

  func testDevinCanBeFoundByItsCompanyOrCLIName() {
    for query in ["Cognition", "Devin CLI"] {
      XCTAssertEqual(providers(matching: query), [.devin], "Query: \(query)")
    }
  }

  func testGLMSearchKeepsChinaAndInternationalAccountsDistinct() {
    XCTAssertEqual(Set(providers(matching: "GLM")), [.zhipu, .zai])
    XCTAssertEqual(providers(matching: "GLM China"), [.zhipu])
    XCTAssertEqual(providers(matching: "GLM international"), [.zai])
    XCTAssertEqual(providers(matching: "z.ai"), [.zai])
    for query in ["BigModel", "智谱"] {
      XCTAssertEqual(providers(matching: query), [.zhipu], "Query: \(query)")
    }
  }

  func testExistingProviderDisplayNamesRemainSearchable() {
    let names: [(String, QuotaProvider)] = [
      ("Google Antigravity", .googleAntigravity), ("JetBrains Junie", .junie),
      ("Meta Muse", .metaMuse), ("Xiaomi MiMo", .xiaomiMiMo)
    ]
    for (name, provider) in names {
      XCTAssertEqual(providers(matching: name), [provider], "Query: \(name)")
    }
  }

  func testBlankQueriesShowAllProvidersAndUnknownQueriesShowNone() {
    for blank in ["", " ", "\t\n  \r"] {
      XCTAssertEqual(ProviderCatalog.search(blank), ProviderCatalog.entries)
    }
    XCTAssertTrue(ProviderCatalog.search("DefinitelyNotAnLLMProvider").isEmpty)
  }

  func testSearchIgnoresCaseAndDiacritics() {
    for query in ["OPENAI", "óPÉnÁI"] {
      XCTAssertEqual(providers(matching: query), [.openAI], "Query: \(query)")
    }
    XCTAssertEqual(providers(matching: "cóGNÍTÍÓN"), [.devin])
    XCTAssertEqual(providers(matching: "jétBRáins jÚnie"), [.junie])
    XCTAssertEqual(providers(matching: "  gLm\tINTERNATIONAL\n"), [.zai])
  }

  func testDetectedAccountSearchIncludesNamesAndSourcesButNeverSecrets() {
    let candidate = DiscoveredCredential(stableID: "codex:fixture", provider: .openAI,
      suggestedName: "Personal reader@example.test", sourceLabel: "Codex CLI (~/.codex)",
      credentials: [CredentialField.openAIAccessToken: "never-searchable-secret-fixture"])
    for query in ["OpenAI", "Codex reader", "PERSONAL", "~/.codex", ""] {
      XCTAssertEqual(ProviderCatalog.search(query, credentials: [candidate]), [candidate], "Query: \(query)")
    }
    for query in ["Cognition", "never-searchable-secret-fixture"] {
      XCTAssertTrue(ProviderCatalog.search(query, credentials: [candidate]).isEmpty)
    }
  }
}
