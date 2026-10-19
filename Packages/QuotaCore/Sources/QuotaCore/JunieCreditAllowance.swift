import Foundation

/// Matches allowance edits to the numeric basis used by Junie's percentages.
public enum JunieCreditAllowance {
  public static func hasChanged(from previous: String?, to updated: String?) -> Bool {
    let previous = nonEmptyString(previous)
    let updated = nonEmptyString(updated)
    guard previous != updated else { return false }
    guard let previous, let updated,
          let oldValue = parse(previous), let newValue = parse(updated) else { return true }
    return oldValue != newValue
  }

  static func parse(_ text: String) -> Double? {
    guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite, value >= 0 else { return nil }
    return value
  }
}
