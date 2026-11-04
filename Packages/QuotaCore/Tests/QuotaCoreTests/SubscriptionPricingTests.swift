import Foundation
import XCTest
@testable import QuotaCore

final class SubscriptionPricingTests: XCTestCase {
  func testLegacyAccountDecodesWithoutSubscriptionPricing() throws {
    let legacy = #"{"id":"legacy","provider":"openai","displayName":"Legacy account","isEnabled":true,"credentials":{"openai.access_token":"inert-fixture"}}"#
    let account = try JSONDecoder().decode(ProviderAccount.self, from: Data(legacy.utf8))
    XCTAssertEqual(account.id, "legacy")
    XCTAssertNil(account.subscriptionPricing)
    XCTAssertEqual(account.credentials[CredentialField.openAIAccessToken], "inert-fixture")
  }

  func testPricingValidatesNonnegativeFiniteAmountAndUppercaseCurrency() throws {
    for amount in [0, 0.01, 20, Double.greatestFiniteMagnitude] {
      let price = SubscriptionPricing(amount: amount, currency: "CHF", billingPeriod: .monthly)
      XCTAssertEqual(try price.validated(), price)
    }
    for amount in [-0.01, -1, Double.nan, Double.infinity, -Double.infinity] {
      XCTAssertThrowsError(try SubscriptionPricing(amount: amount).validated())
    }
    for currency in ["", "US", "USDD", "usd", "Usd", " USD", "USD ", "U$D", "ÜSD", "123", "US\n"] {
      XCTAssertThrowsError(try SubscriptionPricing(amount: 20, currency: currency).validated(), currency)
    }
  }

  func testMonthlyEquivalentPreservesMonthlyPriceAndDividesAnnualPriceByTwelve() throws {
    let monthly = try SubscriptionPricing(amount: 29.99, currency: "USD", billingPeriod: .monthly).validated()
    let yearly = try SubscriptionPricing(amount: 240, currency: "USD", billingPeriod: .yearly).validated()
    XCTAssertEqual(monthly.monthlyEquivalent, 29.99)
    XCTAssertEqual(yearly.monthlyEquivalent, 20)
    XCTAssertEqual(SubscriptionPricing(amount: 0, billingPeriod: .yearly).monthlyEquivalent, 0)
    XCTAssertEqual(SubscriptionBillingPeriod.allCases, [.monthly, .yearly])
    XCTAssertEqual(SubscriptionBillingPeriod.monthly.displayName, "Monthly")
    XCTAssertEqual(SubscriptionBillingPeriod.yearly.displayName, "Yearly")
  }

  func testDecodedPricingStillRequiresValidation() throws {
    let invalid = #"{"amount":-20,"currency":"usd","billingPeriod":"monthly"}"#
    let pricing = try JSONDecoder().decode(SubscriptionPricing.self, from: Data(invalid.utf8))
    XCTAssertThrowsError(try pricing.validated())
  }

  func testSettingsRoundTripKeepsIndependentAccountSubscriptionPrices() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    let first = ProviderAccount(id: "first", provider: .openAI, credentials: [CredentialField.openAIAccessToken: "fixture-first"],
      subscriptionPricing: SubscriptionPricing(amount: 200, currency: "USD", billingPeriod: .monthly))
    let second = ProviderAccount(id: "second", provider: .junie, credentials: [CredentialField.junieAPIKey: "fixture-second"],
      subscriptionPricing: SubscriptionPricing(amount: 180, currency: "CHF", billingPeriod: .yearly))
    let settings = AppSettings(accounts: [first, second])
    try store.save(settings)
    let loaded = try store.load()
    XCTAssertEqual(loaded.accounts, [first, second])
    XCTAssertEqual(loaded.accounts[0].subscriptionPricing?.amount, 200)
    XCTAssertEqual(loaded.accounts[1].subscriptionPricing?.monthlyEquivalent, 15)
  }

  func testRedactionRetainsNonsecretPricingAndRemovesCredentials() throws {
    let price = SubscriptionPricing(amount: 200, currency: "USD", billingPeriod: .monthly)
    let account = ProviderAccount(provider: .openAI, credentials: [CredentialField.openAIAccessToken: "fixture-private-value"],
      subscriptionPricing: price)
    let redacted = account.redactedCredentials()
    XCTAssertTrue(redacted.credentials.isEmpty)
    XCTAssertEqual(redacted.subscriptionPricing, price)
    let settings = AppSettings(accounts: [account]).redactedCredentials()
    XCTAssertEqual(settings.accounts.first?.subscriptionPricing, price)
    let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    XCTAssertFalse(encoded.contains("fixture-private-value"))
    XCTAssertTrue(encoded.contains("subscriptionPricing"))
  }

  func testCredentialImportKeepsAccountOwnedPrice() {
    let price = SubscriptionPricing(amount: 35, currency: "USD", billingPeriod: .monthly)
    var account = ProviderAccount(provider: .junie, credentials: [CredentialField.junieAPIKey: "fixture-old"], subscriptionPricing: price)
    account.credentials = account.credentialsForImport([CredentialField.junieAPIKey: "fixture-new"])
    XCTAssertEqual(account.credentials[CredentialField.junieAPIKey], "fixture-new")
    XCTAssertEqual(account.subscriptionPricing, price)
  }
}
