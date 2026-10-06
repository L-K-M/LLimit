import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPClientTests: XCTestCase {
  // Regression test: cancelling a refresh (app quit, task timeout) must
  // propagate as CancellationError so callers can drop the result. Wrapping
  // it into `.network` persisted a bogus provider failure into the snapshot.
  func testCancelledTransportErrorIsRethrownAsCancellation() async {
    let session = URLSession(configuration: Self.configuration())
    let client = URLSessionHTTPClient(session: session)

    StubURLProtocol.failure = URLError(.cancelled)
    defer { StubURLProtocol.failure = nil }

    do {
      _ = try await client.data(for: URLRequest(url: URL(string: "https://example.invalid/quota")!))
      XCTFail("Expected a cancellation error")
    } catch is CancellationError {
      // expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testPlainTransportErrorBecomesNetworkFailure() async {
    let session = URLSession(configuration: Self.configuration())
    let client = URLSessionHTTPClient(session: session)

    StubURLProtocol.failure = URLError(.notConnectedToInternet)
    defer { StubURLProtocol.failure = nil }

    do {
      _ = try await client.data(for: URLRequest(url: URL(string: "https://example.invalid/quota")!))
      XCTFail("Expected a network failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .network)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return configuration
  }
}

/// Fails every request with `failure` when set, so tests can drive the exact
/// transport error `URLSessionHTTPClient` has to translate.
final class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var failure: Error?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let failure = Self.failure ?? URLError(.badURL)
    client?.urlProtocol(self, didFailWithError: failure)
  }

  override func stopLoading() {}
}
