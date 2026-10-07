import XCTest
@testable import QuotaCore

final class EditableAccountFieldTests: XCTestCase {
  private let veniceKey = EditableAccountField.credential(CredentialField.veniceAPIKey)
  private let venice = ProviderAccount(
    id: "venice",
    provider: .venice,
    displayName: "Venice Work",
    credentials: [CredentialField.veniceAPIKey: "key-a"]
  )

  func testRevertedCredentialEditIsNotAChange() {
    // Typing A, AB, then A again must not count as replacing the key.
    XCTAssertNil(venice.committedText("key-a", for: veniceKey))
  }

  func testSurroundingWhitespaceIsNotACredentialChange() {
    XCTAssertNil(venice.committedText("  key-a\n", for: veniceKey))

    var legacy = venice
    legacy.credentials[CredentialField.veniceAPIKey] = "key-a "
    XCTAssertNil(legacy.committedText("key-a", for: veniceKey))
  }

  func testReplacedCredentialSavesTrimmedValue() {
    XCTAssertEqual(venice.committedText(" key-b\n", for: veniceKey), "key-b")
  }

  func testClearingCredentialIsAChange() {
    XCTAssertEqual(venice.committedText("   ", for: veniceKey), "")
  }

  func testBlankDraftForMissingCredentialIsNotAChange() {
    let field = EditableAccountField.credential(CredentialField.copilotUsername)
    let copilot = ProviderAccount(id: "copilot", provider: .gitHubCopilot)

    XCTAssertNil(copilot.committedText("", for: field))
    XCTAssertNil(copilot.committedText(" \n", for: field))
    XCTAssertEqual(copilot.committedText("octocat", for: field), "octocat")
  }

  func testUnchangedDisplayNameIsNotAChange() {
    XCTAssertNil(venice.committedText("Venice Work", for: .displayName))
    XCTAssertNil(venice.committedText(" Venice Work \n", for: .displayName))
  }

  func testRenamedDisplayNameSavesTrimmedValue() {
    XCTAssertEqual(venice.committedText("  Personal ", for: .displayName), "Personal")
  }

  func testBlankDisplayNameFallsBackToProviderName() {
    XCTAssertEqual(venice.committedText("  ", for: .displayName), QuotaProvider.venice.displayName)

    let defaultName = ProviderAccount(id: "venice-default", provider: .venice)
    XCTAssertNil(defaultName.committedText("", for: .displayName))
  }

  func testSavedTextShowsStoredValues() {
    XCTAssertEqual(venice.savedText(for: .displayName), "Venice Work")
    XCTAssertEqual(venice.savedText(for: veniceKey), "key-a")
    XCTAssertEqual(venice.savedText(for: .credential(CredentialField.veniceAPIKey + "-missing")), "")
  }
}
