import Foundation

/// Parsed `llimit resets` options.
public struct ResetsOptions: Equatable, Sendable {
  public var asJSON: Bool
  public var days: Int

  /// The window the README documents as the contract.
  public static let supportedDays = 1...90

  public init(asJSON: Bool = false, days: Int = 7) {
    self.asJSON = asJSON
    self.days = days
  }
}

/// Why a `llimit resets` argument list was rejected. The messages are the CLI's
/// user-facing copy; keep them stable.
public enum ResetsOptionError: Error, Equatable, Sendable {
  case unknownOption(String)
  case missingDaysValue
  case invalidDaysValue(String)
  case daysOutOfRange(Int)

  public var message: String {
    switch self {
    case .unknownOption(let option):
      return "unknown option: \(option)"
    case .missingDaysValue, .invalidDaysValue:
      return "--days needs a whole number of days"
    case .daysOutOfRange:
      // Derived from the single source of truth so the copy cannot drift from
      // the range the parser actually enforces.
      let range = ResetsOptions.supportedDays
      return "--days must be between \(range.lowerBound) and \(range.upperBound)"
    }
  }
}

/// Side-effect-free parser for `llimit resets`, so the CLI's validation is
/// testable without spawning the process.
public func parseResetsOptions(_ args: [String]) throws -> ResetsOptions {
  var options = ResetsOptions()
  var index = 0

  while index < args.count {
    switch args[index] {
    case "--json":
      options.asJSON = true
    case "--days":
      guard index + 1 < args.count else { throw ResetsOptionError.missingDaysValue }
      let raw = args[index + 1]
      guard let value = Int(raw) else { throw ResetsOptionError.invalidDaysValue(raw) }
      guard ResetsOptions.supportedDays.contains(value) else {
        throw ResetsOptionError.daysOutOfRange(value)
      }
      index += 1
      options.days = value
    default:
      throw ResetsOptionError.unknownOption(args[index])
    }
    index += 1
  }

  return options
}
