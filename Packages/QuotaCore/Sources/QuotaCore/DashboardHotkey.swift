import Foundation

/// Optional global shortcut that shows or hides the floating dashboard on macOS.
///
/// A short list of fixed presets instead of a free-form recorder: a global hot
/// key takes its combination away from every other app, so each preset avoids
/// shortcuts that macOS and common apps already use. Option-Command-L, for
/// example, opens Downloads in Finder, Safari, and Chrome.
///
/// The choice is a display preference kept in UserDefaults, not in the
/// credential settings file. Raw values are persisted, so never rename them.
public enum DashboardHotkey: String, CaseIterable, Sendable {
  case off
  case controlOptionCommandL = "control-option-command-l"
  case controlOptionL = "control-option-l"
  case controlOptionShiftCommandL = "control-option-shift-command-l"

  /// UserDefaults key holding the chosen raw value.
  public static let defaultsKey = "DashboardHotkey"

  /// Key every preset combines with its modifiers (L for LLimit).
  public static let keySymbol = "L"

  /// Modifier keys, declared in the order macOS menus display them.
  public enum Modifier: CaseIterable, Sendable {
    case control
    case option
    case shift
    case command

    public var symbol: String {
      switch self {
      case .control:
        return "⌃"
      case .option:
        return "⌥"
      case .shift:
        return "⇧"
      case .command:
        return "⌘"
      }
    }
  }

  /// A stored choice. Missing or unknown values, such as one written by a newer
  /// build, mean off: the app never registers a shortcut you did not pick.
  public init(storedValue: String?) {
    self = storedValue.flatMap(DashboardHotkey.init(rawValue:)) ?? .off
  }

  /// Modifier keys held with `keySymbol`, or nil when the shortcut is off.
  public var modifiers: Set<Modifier>? {
    switch self {
    case .off:
      return nil
    case .controlOptionCommandL:
      return [.control, .option, .command]
    case .controlOptionL:
      return [.control, .option]
    case .controlOptionShiftCommandL:
      return [.control, .option, .shift, .command]
    }
  }

  /// "Off", or the shortcut as macOS menus show it, such as "⌃⌥⌘L".
  public var displayName: String {
    guard let modifiers else { return "Off" }
    let symbols = Modifier.allCases.filter { modifiers.contains($0) }.map(\.symbol)
    return symbols.joined() + Self.keySymbol
  }
}
