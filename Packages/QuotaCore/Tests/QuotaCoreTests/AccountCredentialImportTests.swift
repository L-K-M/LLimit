import XCTest
@testable import QuotaCore

final class AccountCredentialImportTests: XCTestCase {
  // Inert fixtures consumed only by the account-import transformations below.
  private let originalFixture = "original-fixture-value"
  private let importedFixture = "imported-fixture-value"
  private let obsoleteFixture = "obsolete-fixture-value"

  func testJuniePreservesAllowanceWhileReplacingAuthentication() {
    for allowance in ["70", "0"] {
      let account = ProviderAccount(provider: .junie, credentials: [
        CredentialField.junieAPIKey: originalFixture,
        CredentialField.junieCreditAllowance: allowance,
        "obsolete": obsoleteFixture
      ])
      let imported = [CredentialField.junieAPIKey: importedFixture]

      XCTAssertEqual(account.credentialsForImport(imported), [
        CredentialField.junieAPIKey: importedFixture,
        CredentialField.junieCreditAllowance: allowance
      ])
      XCTAssertEqual(account.credentials[CredentialField.junieAPIKey], originalFixture)
    }
  }

  func testExplicitImportedAllowanceWinsIncludingZeroAndBlank() {
    let account = ProviderAccount(provider: .junie, credentials: [
      CredentialField.junieAPIKey: originalFixture,
      CredentialField.junieCreditAllowance: "70"
    ])
    for allowance in ["10", "0", ""] {
      let imported = [
        CredentialField.junieAPIKey: importedFixture,
        CredentialField.junieCreditAllowance: allowance
      ]

      XCTAssertEqual(account.credentialsForImport(imported), imported)
    }
  }

  func testOtherProvidersReplaceWholeCredentialSet() {
    let account = ProviderAccount(provider: .openAI, credentials: [
      CredentialField.openAIAccessToken: originalFixture,
      CredentialField.openAIAccountID: obsoleteFixture,
      CredentialField.junieCreditAllowance: "70"
    ])
    let imported = [CredentialField.openAIAccessToken: importedFixture]

    XCTAssertEqual(account.credentialsForImport(imported), imported)
  }

  func testEmptyJunieImportRetainsOnlyAllowance() {
    let account = ProviderAccount(provider: .junie, credentials: [
      CredentialField.junieAPIKey: originalFixture,
      CredentialField.junieCreditAllowance: "0",
      "obsolete": obsoleteFixture
    ])

    XCTAssertEqual(account.credentialsForImport([:]), [CredentialField.junieCreditAllowance: "0"])
  }

  func testJunieImportWithoutStoredAllowanceAddsNoDefault() {
    let account = ProviderAccount(provider: .junie, credentials: [
      CredentialField.junieAPIKey: originalFixture,
      "obsolete": obsoleteFixture
    ])
    let imported = [CredentialField.junieAPIKey: importedFixture]

    XCTAssertEqual(account.credentialsForImport(imported), imported)
  }
}
