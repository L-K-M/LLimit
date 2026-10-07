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
