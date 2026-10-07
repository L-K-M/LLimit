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
    } catch let error as ProviderClientError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw ProviderClientError(kind: .network, message: "Could not reach the provider. Check your connection and try again.")
    }
  }
}
