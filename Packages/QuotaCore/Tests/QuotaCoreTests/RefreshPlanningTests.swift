import XCTest
@testable import QuotaCore

final class RefreshAvailabilityTests: XCTestCase {
  private let claude = ProviderAccount(id: "claude", provider: .anthropic, credentials: [CredentialField.anthropicAccessToken: "token"])
  private let openAI = ProviderAccount(id: "openai", provider: .openAI, credentials: [
    CredentialField.openAIAccessToken: "token",
    CredentialField.openAIAccountID: "account"
  ])

  func testRunningRefreshWins() {
    let availability = RefreshAvailability(isRefreshing: true, accounts: [claude], signingInAccountIDs: [])

    XCTAssertEqual(availability, .refreshing)
    XCTAssertFalse(availability.allowsRefresh)
  }

  func testOtherAccountsStayRefreshableDuringSignIn() {
    let availability = RefreshAvailability(isRefreshing: false, accounts: [claude, openAI], signingInAccountIDs: ["openai"])

    XCTAssertEqual(availability, .ready)
    XCTAssertTrue(availability.allowsRefresh)
    XCTAssertNil(availability.reason)
  }

  func testWaitsWhenEveryRefreshableAccountIsSigningIn() {
    let availability = RefreshAvailability(isRefreshing: false, accounts: [openAI], signingInAccountIDs: ["openai"])

    XCTAssertEqual(availability, .waitingForSignIn(.openAI))
    XCTAssertFalse(availability.allowsRefresh)
    XCTAssertEqual(availability.reason, "Waiting for OpenAI sign-in")
  }

  func testNewAccountSigningInIsWaitingRatherThanIncomplete() {
    let added = ProviderAccount(id: "new", provider: .openAI)
    let availability = RefreshAvailability(isRefreshing: false, accounts: [added], signingInAccountIDs: ["new"])

    XCTAssertEqual(availability, .waitingForSignIn(.openAI))
  }

  func testDisabledAccountSigningInDoesNotWait() {
    var disabled = openAI
    disabled.isEnabled = false
    let availability = RefreshAvailability(isRefreshing: false, accounts: [disabled], signingInAccountIDs: ["openai"])

    XCTAssertEqual(availability, .noCompleteAccounts)
  }

  func testNoEnabledCompleteAccount() {
    var disabled = claude
    disabled.isEnabled = false
    let incomplete = ProviderAccount(id: "zai", provider: .zai)

    for accounts in [[], [disabled], [incomplete]] {
      let availability = RefreshAvailability(isRefreshing: false, accounts: accounts, signingInAccountIDs: [])
      XCTAssertEqual(availability, .noCompleteAccounts)
      XCTAssertFalse(availability.allowsRefresh)
      XCTAssertNotNil(availability.reason)
    }
  }

  func testManagedClaudeProfileWithoutTokenIsRefreshable() {
    // Each cycle renews a managed profile first and reports its failure, so it is never a no-op.
    let managed = ProviderAccount(id: "managed", provider: .anthropic, credentials: [
      CredentialField.anthropicProfileID: UUID().uuidString,
      CredentialField.anthropicCredentialSource: ClaudeCodeCredentialSource.managedProfile.rawValue
    ])
    let availability = RefreshAvailability(isRefreshing: false, accounts: [managed], signingInAccountIDs: [])

    XCTAssertEqual(availability, .ready)
  }

  func testImportedOpenAILoginWithoutAccessTokenIsRefreshable() {
    // Each cycle renews or adopts an imported login's access token before fetching.
    for credentials in [[CredentialField.openAIRefreshToken: "refresh"], [CredentialField.openAIAccountID: "account"]] {
      let imported = ProviderAccount(id: "imported", provider: .openAI, credentials: credentials)
      let availability = RefreshAvailability(isRefreshing: false, accounts: [imported], signingInAccountIDs: [])
      XCTAssertEqual(availability, .ready)
    }
  }

  func testOpenAILoginWithNothingToRenewIsIncomplete() {
    let empty = ProviderAccount(id: "empty", provider: .openAI, credentials: [CredentialField.openAIRefreshToken: " "])
    let managed = ProviderAccount(id: "managed", provider: .openAI, credentials: [
      CredentialField.openAIRefreshToken: "refresh",
      CredentialField.openAIAccountID: "account",
      // A managed profile without its verified identity needs a reconnect, not a refresh.
      CredentialField.openAICodexProfileID: UUID().uuidString
    ])

    for account in [empty, managed] {
      let availability = RefreshAvailability(isRefreshing: false, accounts: [account], signingInAccountIDs: [])
      XCTAssertEqual(availability, .noCompleteAccounts)
    }
  }

  func testHelpExplainsEveryState() {
    XCTAssertFalse(RefreshAvailability.ready.help.isEmpty)
    XCTAssertEqual(RefreshAvailability.refreshing.help, RefreshAvailability.refreshing.reason)
    XCTAssertEqual(RefreshAvailability.waitingForSignIn(.openAI).help, "Waiting for OpenAI sign-in")
    XCTAssertEqual(RefreshAvailability.noCompleteAccounts.help, RefreshAvailability.noCompleteAccounts.reason)
  }
}

final class RefreshSelectionTests: XCTestCase {
  private func configuration(_ id: String, _ provider: QuotaProvider, enabled: Bool = true,
                             credentials: [String: String]) -> ProviderRuntimeConfiguration {
    ProviderRuntimeConfiguration(accountID: id, provider: provider, isEnabled: enabled, credentials: credentials)
  }

  private var claude: ProviderRuntimeConfiguration {
    configuration("claude", .anthropic, credentials: [CredentialField.anthropicAccessToken: "token"])
  }

  private var openAI: ProviderRuntimeConfiguration {
    configuration("openai", .openAI, credentials: [
      CredentialField.openAIAccessToken: "token",
      CredentialField.openAIAccountID: "account"
    ])
  }

  func testSkipsSigningInAccountAndFetchesTheRest() {
    let selection = RefreshSelection(configurations: [claude, openAI], failedPreparation: [], signingInAccountIDs: ["openai"])

    XCTAssertEqual(selection.fetched.map(\.accountID), ["claude"])
    XCTAssertEqual(selection.skippedAccountIDs, ["openai"])
  }

  func testWithoutSignInEveryEligibleAccountIsFetchedInOrder() {
    let selection = RefreshSelection(configurations: [openAI, claude], failedPreparation: [], signingInAccountIDs: [])

    XCTAssertEqual(selection.fetched.map(\.accountID), ["openai", "claude"])
    XCTAssertTrue(selection.skippedAccountIDs.isEmpty)
  }

  func testIneligibleAccountsAreNeitherFetchedNorSkipped() {
    var disabled = openAI
    disabled.isEnabled = false
    let added = configuration("new", .openAI, credentials: [:])

    let selection = RefreshSelection(
      configurations: [claude, disabled, added],
      failedPreparation: ["claude"],
      signingInAccountIDs: ["openai", "new"]
    )

    XCTAssertTrue(selection.fetched.isEmpty)
    // Nothing was fetched for them before either, so there is nothing to keep.
    XCTAssertTrue(selection.skippedAccountIDs.isEmpty)
  }
}

final class SkippedAccountResultsTests: XCTestCase {
  private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
  private let now = Date(timeIntervalSince1970: 1_700_003_600)

  private func usage(_ accountID: String, _ provider: QuotaProvider, remaining: Int, at date: Date) -> ProviderUsage {
    ProviderUsage(
      accountID: accountID,
      provider: provider,
      title: provider.displayName,
      metrics: [UsageMetric(id: "m", label: "limit", remainingPercent: remaining)],
      maxUsagePercent: 100 - remaining,
      fetchedAt: date
    )
  }

  func testSkippedAccountKeepsItsLastUsageAndFailure() {
    let previous = QuotaSnapshot(
      generatedAt: earlier,
      providers: [usage("claude", .anthropic, remaining: 10, at: earlier), usage("openai", .openAI, remaining: 40, at: earlier)],
      failures: [ProviderFailure(accountID: "openai", provider: .openAI, kind: .auth, message: "Reconnect")]
    )
    let fresh = QuotaSnapshot(generatedAt: now, providers: [usage("claude", .anthropic, remaining: 70, at: now)], failures: [])

    let result = fresh.carryingResults(forSkippedAccountIDs: ["openai"], from: previous)

    XCTAssertEqual(result.generatedAt, now)
    XCTAssertEqual(result.providers.first { $0.accountID == "claude" }?.metrics.first?.remainingPercent, 70)
    let carried = result.providers.first { $0.accountID == "openai" }
    XCTAssertEqual(carried?.metrics.first?.remainingPercent, 40)
    // The original timestamp still shows how old the carried usage is.
    XCTAssertEqual(carried?.fetchedAt, earlier)
    XCTAssertEqual(result.failures.map(\.accountID), ["openai"])
  }

  func testSkippedAccountWithoutEarlierResultStaysAbsent() {
    let previous = QuotaSnapshot(generatedAt: earlier, providers: [], failures: [])
    let fresh = QuotaSnapshot(generatedAt: now, providers: [usage("claude", .anthropic, remaining: 70, at: now)], failures: [])

    XCTAssertEqual(fresh.carryingResults(forSkippedAccountIDs: ["openai"], from: previous), fresh)
  }

  func testWithoutPreviousSnapshotNothingIsCarried() {
    let fresh = QuotaSnapshot(generatedAt: now, providers: [usage("claude", .anthropic, remaining: 70, at: now)], failures: [])

    XCTAssertEqual(fresh.carryingResults(forSkippedAccountIDs: ["openai"], from: nil), fresh)
  }
}
