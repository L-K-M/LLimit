import Foundation

public struct ProviderClientError: LocalizedError, Sendable {
  public var kind: QuotaErrorKind
  public var message: String
  public var statusCode: Int?
  /// Seconds the server asked us to wait (from `Retry-After`) before the next
  /// attempt. Nil when the server sent no usable guidance.
  public var retryAfter: TimeInterval?

  public init(kind: QuotaErrorKind, message: String, statusCode: Int? = nil, retryAfter: TimeInterval? = nil) {
    self.kind = kind
    self.message = message
    self.statusCode = statusCode
    self.retryAfter = retryAfter
  }

  public var errorDescription: String? { message }
}
