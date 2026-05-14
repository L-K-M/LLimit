import Foundation

public struct ProviderClientError: LocalizedError, Sendable {
  public var kind: QuotaErrorKind
  public var message: String
  public var statusCode: Int?

  public init(kind: QuotaErrorKind, message: String, statusCode: Int? = nil) {
    self.kind = kind
    self.message = message
    self.statusCode = statusCode
  }

  public var errorDescription: String? { message }
}
