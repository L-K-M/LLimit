import Foundation
import Combine
// Kept out of the SwiftUI view files: HIToolbox also exports a global
// `Button()` function that would compete with SwiftUI's `Button`.
import Carbon.HIToolbox
import QuotaCore

/// Registers the optional global shortcut that shows or hides the floating
/// dashboard, chosen in Settings > General. Carbon hot keys need no
/// Accessibility permission. The app delegate starts the service after launch
/// and stops it at quit. At most one shortcut is registered at a time.
@MainActor
final class GlobalHotkeyService: ObservableObject {
  static let shared = GlobalHotkeyService()

  @Published private(set) var shortcut: DashboardHotkey
  /// Why the chosen shortcut is not active, shown next to the picker.
  @Published private(set) var registrationError: String?
  /// Runs for every press of the registered shortcut.
  var onPress: (@MainActor () -> Void)?

  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var isStarted = false

  private init() {
    shortcut = DashboardHotkey(storedValue: UserDefaults.standard.string(forKey: DashboardHotkey.defaultsKey))
  }

  func start() {
    isStarted = true
    register(shortcut)
  }

  func stop() {
    isStarted = false
    unregisterHotKey()

    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  /// Saves the choice and replaces the registered shortcut. Off removes it.
  func select(_ newShortcut: DashboardHotkey) {
    UserDefaults.standard.set(newShortcut.rawValue, forKey: DashboardHotkey.defaultsKey)
    shortcut = newShortcut

    guard isStarted else { return }
    register(newShortcut)
  }

  fileprivate func handlePress() {
    onPress?()
  }

  private func register(_ shortcut: DashboardHotkey) {
    unregisterHotKey()
    registrationError = nil

    guard let modifiers = shortcut.modifiers, installEventHandlerIfNeeded() else { return }

    var hotKey: EventHotKeyRef?
    // Exclusive, so presses reach only LLimit and a combination another app
    // already holds exclusively fails here, where Settings can report it.
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_L), // DashboardHotkey.keySymbol
      modifiers.reduce(UInt32(0)) { $0 | $1.carbonFlag },
      EventHotKeyID(signature: dashboardHotkeySignature, id: 1),
      GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive),
      &hotKey
    )
    guard status == noErr, let hotKey else {
      registrationError = status == OSStatus(eventHotKeyExistsErr)
        ? "Another app already uses \(shortcut.displayName). Choose a different shortcut."
        : "Could not register \(shortcut.displayName) (error \(status))."
      return
    }

    self.hotKey = hotKey
  }

  private func unregisterHotKey() {
    guard let hotKey else { return }
    UnregisterEventHotKey(hotKey)
    self.hotKey = nil
  }

  private func installEventHandlerIfNeeded() -> Bool {
    guard eventHandler == nil else { return true }

    var hotKeyPressed = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    var handler: EventHandlerRef?
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      dashboardHotkeyPressed,
      1,
      &hotKeyPressed,
      nil,
      &handler
    )
    guard status == noErr, let handler else {
      registrationError = "Could not listen for the shortcut (error \(status))."
      return false
    }

    eventHandler = handler
    return true
  }
}

private extension DashboardHotkey.Modifier {
  var carbonFlag: UInt32 {
    switch self {
    case .control:
      return UInt32(controlKey)
    case .option:
      return UInt32(optionKey)
    case .shift:
      return UInt32(shiftKey)
    case .command:
      return UInt32(cmdKey)
    }
  }
}

/// Marks LLimit's hot key events with the four-character code "LLmt".
private let dashboardHotkeySignature: OSType = "LLmt".utf8.reduce(0) { ($0 << 8) | OSType($1) }

/// Carbon calls this on the main event loop with no Swift context attached.
/// It only checks that the event is LLimit's hot key, then hops to the main
/// actor to handle the press.
private func dashboardHotkeyPressed(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }

  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr, hotKeyID.signature == dashboardHotkeySignature else {
    return OSStatus(eventNotHandledErr)
  }

  Task { @MainActor in
    GlobalHotkeyService.shared.handlePress()
  }
  return noErr
}
