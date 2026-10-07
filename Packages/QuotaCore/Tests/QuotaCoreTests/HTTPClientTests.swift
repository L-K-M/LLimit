import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPClientTests: XCTestCase {
  func testTransportCancellationIsNotAProviderFailure() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CancelledURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    do {
      _ = try await URLSessionHTTPClient(session: session).data(for: URLRequest(url: URL(string: "https://example.invalid/quota")!))
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private final class CancelledURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
  override func stopLoading() {}
}
