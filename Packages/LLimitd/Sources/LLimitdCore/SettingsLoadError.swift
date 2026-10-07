import Foundation

/// Decoder descriptions may echo credentials. Report only the structural failure.
public struct SettingsLoadError: LocalizedError, Equatable, Sendable {
  public let fileURL: URL
  public let reason: String

  public init(fileURL: URL, error: Error) {
    self.fileURL = fileURL
    switch error {
    case DecodingError.keyNotFound(let key, let context):
      reason = "missing key \"\(key.stringValue)\"\(Self.location(context.codingPath))"
    case DecodingError.typeMismatch(let type, let context):
      reason = "wrong type\(Self.location(context.codingPath)), expected \(type)"
    case DecodingError.valueNotFound(let type, let context):
      reason = "missing value\(Self.location(context.codingPath)), expected \(type)"
    case DecodingError.dataCorrupted(let context):
      reason = context.codingPath.isEmpty ? "not valid JSON" : "invalid value\(Self.location(context.codingPath))"
    default:
      reason = "could not read file"
    }
  }

  public var errorDescription: String? {
    "Could not load settings file \(fileURL.path): \(reason). Fix it or move it aside; LLimit will not overwrite it."
  }

  private static func location(_ keys: [CodingKey]) -> String {
    guard !keys.isEmpty else { return "" }
    var path = ""
    for key in keys {
      if let index = key.intValue { path += "[\(index)]" }
      else { path += path.isEmpty ? key.stringValue : ".\(key.stringValue)" }
    }
    return " at \(path)"
  }
}
