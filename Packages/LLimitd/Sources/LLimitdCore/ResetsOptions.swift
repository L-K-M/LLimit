import Foundation

public struct ResetsOptions: Equatable, Sendable {
  public enum Output: Sendable { case human, json }
  public static let supportedDays = 1...90
  public static let defaultDays = 7
  static let defaultHorizon: TimeInterval = TimeInterval(defaultDays) * 86_400
  public var output: Output = .human
  public var days = defaultDays

  public init() {}

  public static func parse(_ args: [String]) throws -> ResetsOptions {
    var options = ResetsOptions()
    var index = 0
    while index < args.count {
      switch args[index] {
      case "--json": options.output = .json
      case "--days":
        let raw = try CommandLineValues.value(after: "--days", in: args, at: &index)
        guard let days = Int(raw) else {
          let digits = raw.hasPrefix("+") || raw.hasPrefix("-") ? raw.dropFirst() : raw[...]
          if !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            throw CommandLineError("--days must be between 1 and 90")
          }
          throw CommandLineError("--days needs a whole number of days")
        }
        guard supportedDays.contains(days) else { throw CommandLineError("--days must be between 1 and 90") }
        options.days = days
      default: throw CommandLineError("unknown resets option: \(args[index])")
      }
      index += 1
    }
    return options
  }
}
