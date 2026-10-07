import Foundation

/// Why the settings file could not be loaded, in a form that is safe to print and
/// log: it names the file and where decoding failed, but never quotes the file. The
/// file holds credentials, and decoder messages can echo the offending value.
public struct SettingsLoadError: LocalizedError, Equatable, Sendable {
  public let fileURL: URL
  /// The decoding location and problem, e.g. "invalid value at accounts[0].provider".
  public let reason: String

  public init(fileURL: URL, error: Error) {
    self.fileURL = fileURL
    self.reason = Self.reason(for: error)
  }

  public var errorDescription: String? {
    "Settings file \(fileURL.path) is unreadable: \(reason). Fix it or move it aside; LLimit will not overwrite it."
  }

  private static func reason(for error: Error) -> String {
    switch error {
    case DecodingError.keyNotFound(let key, let context):
      return "missing key \"\(key.stringValue)\"\(location(context.codingPath))"
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
      // These descriptions name only the expected and found JSON types.
      return "\(context.debugDescription)\(location(context.codingPath))"
    case DecodingError.dataCorrupted(let context):
      // A value-level description can quote the rejected value, so only the
      // location is reported; an empty path means the JSON itself is invalid.
      return context.codingPath.isEmpty ? "not valid JSON" : "invalid value\(location(context.codingPath))"
    default:
      // Not a decoding problem, e.g. missing read permission.
      return error.localizedDescription
    }
  }

  /// Renders a coding path as " at accounts[0].provider"; empty at the root.
  private static func location(_ codingPath: [CodingKey]) -> String {
    guard !codingPath.isEmpty else { return "" }

    var path = ""
    for key in codingPath {
      if let index = key.intValue {
        path += "[\(index)]"
      } else {
        path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
      }
    }
    return " at \(path)"
  }
}
