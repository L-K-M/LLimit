import XCTest
@testable import QuotaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPRedirectIntegrationTests: XCTestCase {
  func testRefusedRedirectNeverReachesAnotherOriginOrChangesTheCookieJar() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-u", "-c", Self.server, folder.path]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    // Graceful fixture shutdown can hang under the asynchronous Linux runner.
    // It has no state to preserve, so cleanup must not wait on SIGTERM.
    defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
    let ready = folder.appendingPathComponent("port")
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard FileManager.default.fileExists(atPath: ready.path) else {
      XCTFail("The local redirect fixture did not start (python3 is required).")
      return
    }
    let port = try String(contentsOf: ready).trimmingCharacters(in: .whitespacesAndNewlines)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/start"))
    let configuration = URLSessionConfiguration.ephemeral
    let jar = try XCTUnwrap(configuration.httpCookieStorage)
    let original = try XCTUnwrap(HTTPCookie(properties: [.name: "original", .value: "fixture-only", .domain: "127.0.0.1", .path: "/"]))
    jar.setCookie(original)
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = URLSessionHTTPClient(session: session, timeoutSeconds: 3)
    var request = URLRequest(url: url)
    request.setValue("session=private-fixture", forHTTPHeaderField: "Cookie")
    let (_, response) = try await client.data(for: request, redirects: .refuse)
    XCTAssertEqual(response.statusCode, 302)
    let records = try String(contentsOf: folder.appendingPathComponent("requests"))
    XCTAssertEqual(records, "start:session=private-fixture\n")
    XCTAssertFalse((jar.cookies ?? []).contains { $0.name == "server_cookie" })

    // A positive control proves the second server can be reached. It receives
    // no explicit session header, and ordinary requests retain redirect behavior.
    let (_, followed) = try await client.data(for: URLRequest(url: url))
    XCTAssertEqual(followed.statusCode, 200)
    let followedRecords = try String(contentsOf: folder.appendingPathComponent("requests"))
    XCTAssertTrue(followedRecords.contains("destination:"))
    XCTAssertFalse(followedRecords.contains("destination:session=private-fixture"))
  }

  private static let server = #"""
  import http.server, threading, pathlib, sys
  folder = pathlib.Path(sys.argv[1])
  class Target(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
          with (folder/'requests').open('a') as f:
              f.write('destination:' + self.headers.get('Cookie', '') + '\n')
          self.send_response(200)
          self.end_headers()
          self.wfile.write(b'ok')
      def log_message(self, *args): pass
  target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
  threading.Thread(target=target.serve_forever, daemon=True).start()
  class Origin(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
          with (folder/'requests').open('a') as f:
              f.write('start:' + self.headers.get('Cookie', '') + '\n')
          self.send_response(302)
          self.send_header('Location', 'http://127.0.0.1:%s/destination' % target.server_port)
          self.send_header('Set-Cookie', 'server_cookie=fixture-only; Path=/')
          self.end_headers()
      def log_message(self, *args): pass
  origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
  (folder/'port').write_text(str(origin.server_port))
  origin.serve_forever()
  """#
}
