import XCTest
@testable import QuotaCore

final class AccountDisplayOrderTests: XCTestCase {
  private let accounts = [
    ProviderAccount(id: "zai", provider: .zai, displayName: "Team", credentials: ["apiKey": "fixture"]),
    ProviderAccount(id: "claude", provider: .anthropic, displayName: "Personal"),
    ProviderAccount(id: "openai", provider: .openAI, displayName: "Work", isEnabled: false),
    ProviderAccount(id: "openai-second", provider: .openAI, displayName: "Second")
  ]

  func testMoveDownUsesDestinationBeforeRemovingSource() {
    let result = reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 0), toOffset: 3)
    XCTAssertEqual(result, [accounts[1], accounts[2], accounts[0], accounts[3]])
  }

  func testMoveUpPreservesEveryAccountValue() {
    let result = reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 3), toOffset: 0)
    XCTAssertEqual(result, [accounts[3], accounts[0], accounts[1], accounts[2]])
  }

  func testMoveDiscontiguousRowsToEndPreservesRelativeOrder() {
    let result = reorderedAccounts(accounts, fromOffsets: IndexSet([0, 2]), toOffset: accounts.count)
    XCTAssertEqual(result, [accounts[1], accounts[3], accounts[0], accounts[2]])
  }

  func testMoveInsideSelectedBlockDoesNotChangeOrder() {
    let result = reorderedAccounts(accounts, fromOffsets: IndexSet([1, 2]), toOffset: 2)
    XCTAssertEqual(result, accounts)
  }

  func testInvalidMoveOffsetsCannotDropAccounts() {
    XCTAssertEqual(reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 0), toOffset: -1), accounts)
    XCTAssertEqual(reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 0), toOffset: 5), accounts)
    XCTAssertEqual(reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 99), toOffset: 0), accounts)
    XCTAssertEqual(reorderedAccounts([], fromOffsets: IndexSet(integer: 0), toOffset: 0), [])
    XCTAssertEqual(
      reorderedAccounts(accounts, fromOffsets: IndexSet([0, 99]), toOffset: 4),
      [accounts[1], accounts[2], accounts[3], accounts[0]]
    )
  }

  func testReorderedAccountsRoundTripWithoutLosingStylesOrCredentials() throws {
    var settings = AppSettings(accounts: accounts)
    settings.providerStyleSettings[0].primaryHexColor = "#123456"
    settings.accounts = reorderedAccounts(settings.accounts, fromOffsets: IndexSet(integer: 0), toOffset: 4)

    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.accounts, settings.accounts)
    XCTAssertEqual(restored.account(withID: "zai")?.credentials, ["apiKey": "fixture"])
    XCTAssertEqual(restored.primaryHexColor(for: "zai"), "#123456")
    XCTAssertEqual(restored.redactedCredentials().accounts.map(\.id), restored.accounts.map(\.id))
  }

  func testReorderingDoesNotRecolorAccountsOrReassignAutomaticTiles() {
    let before = AppSettings(accounts: accounts)
    var after = before
    after.accounts = reorderedAccounts(accounts, fromOffsets: IndexSet([1, 3]), toOffset: 0)

    XCTAssertEqual(after.providerTileAutoOrder, before.providerTileAutoOrder)
    for account in accounts {
      XCTAssertEqual(
        accountColorStep(forAccountID: account.id, in: after.accounts),
        accountColorStep(forAccountID: account.id, in: before.accounts)
      )
    }
  }

  func testUsageFollowsSettingsOrderRegardlessOfRefreshOrder() {
    let usages = [usage(accounts[3]), usage(accounts[1]), usage(accounts[0])]
    let result = orderedUsageForAccounts(usages, accounts: accounts)
    XCTAssertEqual(result.map(\.accountID), ["zai", "claude", "openai-second"])

    let moved = reorderedAccounts(accounts, fromOffsets: IndexSet(integer: 3), toOffset: 0)
    XCTAssertEqual(orderedUsageForAccounts(usages, accounts: moved).map(\.accountID), ["openai-second", "zai", "claude"])
  }

  func testUsageFiltersDisabledDeletedAndMismatchedAccounts() {
    let removed = ProviderAccount(id: "removed", provider: .kimi)
    var mismatched = usage(accounts[0])
    mismatched.provider = .kimi
    let result = orderedUsageForAccounts(
      [usage(accounts[2]), usage(removed), mismatched, usage(accounts[3])], accounts: accounts
    )
    XCTAssertEqual(result.map(\.accountID), ["openai-second"])
  }

  func testUsageOmitsAccountsWithNoSnapshotWithoutInventingBars() {
    XCTAssertEqual(orderedUsageForAccounts([usage(accounts[1])], accounts: accounts), [usage(accounts[1])])
    XCTAssertTrue(orderedUsageForAccounts([], accounts: accounts).isEmpty)
    XCTAssertTrue(orderedUsageForAccounts([usage(accounts[1])], accounts: []).isEmpty)
  }

  func testSoleAccountLegacyUsageGetsCurrentIdentityAndTitle() {
    let account = ProviderAccount(id: "personal", provider: .openAI, displayName: "Personal")
    var legacy = usage(account)
    legacy.accountID = QuotaProvider.openAI.rawValue
    legacy.title = "Old name"
    let result = orderedUsageForAccounts([legacy], accounts: [account])
    XCTAssertEqual(result, [usage(account)])
  }

  func testExactUsageWinsOverLegacyUsageRegardlessOfSnapshotOrder() {
    let account = ProviderAccount(id: "personal", provider: .openAI)
    var legacy = usage(account)
    legacy.accountID = QuotaProvider.openAI.rawValue
    legacy.metrics[0].remainingPercent = 1
    let exact = usage(account)
    XCTAssertEqual(orderedUsageForAccounts([legacy, exact], accounts: [account]), [exact])
    XCTAssertEqual(orderedUsageForAccounts([exact, legacy], accounts: [account]), [exact])
  }

  func testLegacyUsageDoesNotChooseAmongMultipleAccountsEvenIfOneIsDisabled() {
    let enabled = ProviderAccount(id: "personal", provider: .openAI)
    let disabled = ProviderAccount(id: "team", provider: .openAI, isEnabled: false)
    var legacy = usage(enabled)
    legacy.accountID = QuotaProvider.openAI.rawValue
    XCTAssertTrue(orderedUsageForAccounts([legacy], accounts: [enabled, disabled]).isEmpty)
  }

  private func usage(_ account: ProviderAccount) -> ProviderUsage {
    ProviderUsage(
      accountID: account.id,
      provider: account.provider,
      title: account.resolvedDisplayName,
      metrics: [UsageMetric(id: "weekly", label: "Weekly limit", remainingPercent: 60)],
      fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}
