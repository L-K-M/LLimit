import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
  private let session: URLSession
  private let timeoutSeconds: TimeInterval

  public init(session: URLSession = .shared, timeoutSeconds: TimeInterval = 10) {
    self.session = session
    self.timeoutSeconds = timeoutSeconds
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var mutableRequest = request
    mutableRequest.timeoutInterval = timeoutSeconds

    do {
      let (data, response) = try await session.data(for: mutableRequest)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw ProviderClientError(kind: .network, message: "Non-HTTP response")
      }
      return (data, httpResponse)
    } catch {
      if let providerError = error as? ProviderClientError {
        throw providerError
      }
      throw ProviderClientError(kind: .network, message: error.localizedDescription)
    }
  }
}
