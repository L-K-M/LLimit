import Foundation

/// An account value that Settings edits as text. Settings keeps keystrokes in a
/// local draft and commits each field once, so typing never saves partial values.
public enum EditableAccountField: Hashable, Sendable {
  case displayName
  case credential(String)
}

extension ProviderAccount {
  /// The saved value a field shows while it has no draft.
  public func savedText(for field: EditableAccountField) -> String {
    switch field {
    case .displayName:
      return displayName
    case .credential(let key):
      return credentials[key] ?? ""
    }
  }

  /// The value to save when a draft is committed, or nil when the commit would not
  /// change the account. Names and credentials never carry surrounding whitespace,
  /// so reverting an edit (A, AB, A) or a pasted trailing newline is a no-op. That
  /// matters for credentials: replacing a Venice key clears the account's usage
  /// history and DIEM estimate, which must not happen for an unchanged key.
  public func committedText(_ draft: String, for field: EditableAccountField) -> String? {
    switch field {
    case .displayName:
      // Reuse the saved-name rule: trimmed, and blank falls back to the provider name.
      var renamed = self
      renamed.displayName = draft
      let name = renamed.resolvedDisplayName
      return name == resolvedDisplayName ? nil : name
    case .credential(let key):
      let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      let saved = credentials[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return value == saved ? nil : value
    }
  }
}

/// What committing one account field did. Only a rejection leaves the typed text
/// unsaved; Settings then keeps the draft and shows `AccountEditRejection.message`.
public enum AccountEditOutcome: Equatable, Sendable {
  case applied
  case unchanged
  case accountMissing
  case rejected(AccountEditRejection)

  /// Whether the draft is used up. A rejected draft stays for another try.
  public var consumesDraft: Bool {
    if case .rejected = self { return false }
    return true
  }
}

public enum AccountEditRejection: Equatable, Sendable {
  /// An OpenAI browser sign-in for this account is still running.
  case signInInProgress
  /// The account is connected; its official CLI owns the credentials.
  case managedConnection
  /// The settings file could not be read at launch, so a key change cannot be saved.
  case settingsUnreadable
  /// Replacing a Venice key could not first clear the previous key's usage.
  case previousUsageNotCleared

  public var message: String {
    switch self {
    case .signInInProgress:
      return "Not saved while OpenAI sign-in is running. Finish or cancel the sign-in, then try again."
    case .managedConnection:
      return "Not saved because this account is connected. Its sign-in manages these credentials."
    case .settingsUnreadable:
      return "Could not change this key because the settings file could not be read."
    case .previousUsageNotCleared:
      return "Could not clear this account's previous usage. Check LLimit's storage permissions and try again."
    }
  }
}
