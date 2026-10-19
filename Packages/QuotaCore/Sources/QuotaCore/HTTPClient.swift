import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPRedirectPolicy: Sendable {
  case follow
  case refuse
}

public protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPClient {
  func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    guard redirects == .follow else {
      throw ProviderClientError(kind: .network, message: "This connection cannot safely send session credentials.")
    }
    return try await data(for: request)
  }
}

public struct URLSessionHTTPClient: HTTPClient {
  private let session: URLSession
  private let timeoutSeconds: TimeInterval

  public init(session: URLSession = .shared, timeoutSeconds: TimeInterval = 10) {
    self.session = session
    self.timeoutSeconds = timeoutSeconds
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await data(for: request, redirects: .follow)
  }

  public func data(for request: URLRequest, redirects: HTTPRedirectPolicy) async throws -> (Data, HTTPURLResponse) {
    var mutableRequest = request
    mutableRequest.timeoutInterval = timeoutSeconds
    let transport: URLSession
    if redirects == .refuse {
      // Session-cookie requests must not use shared cookie or disk caches.
      // Retain injected configuration (including test protocols), but isolate
      // every such request's storage and reject redirects before forwarding it.
      let configuration = session.configuration
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      transport = URLSession(configuration: configuration)
    } else {
      transport = session
    }
    defer { if transport !== session { transport.finishTasksAndInvalidate() } }

    do {
      let delegate: (any URLSessionTaskDelegate)? = redirects == .refuse ? RefuseRedirects() : nil
      let (data, response) = try await transport.data(for: mutableRequest, delegate: delegate)
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

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
