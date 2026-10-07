import XCTest
@testable import QuotaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class FailurePrivacyTests: XCTestCase {
  private static let serverErrorStatus = 503
  private static let invalidGrantStatus = 400
  private static let tooManyRequestsStatus = 429
  private static let successStatus = 200
  // Independent output contract: a larger production cap must fail these tests.
  private static let maximumMessageScalars = 512
  // Synthetic sentinels, never valid credentials. Shared with diagnostic fixtures.
  fileprivate static let reflectedSecret = "reflected-access-secret"
  fileprivate static let unknownSecret = "server-issued-unknown-token"
  fileprivate static let responseMarker = "UPSTREAM_RESPONSE_BODY"
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testLiveProviderFailuresNeverPublishResponseBodies() async throws {
    let body = "\(Self.responseMarker) <html>\(Self.reflectedSecret) \(Self.unknownSecret)</html>\u{001B}[31m"
      + String(repeating: "x", count: 2_000)
    let coordinator = QuotaCoordinator.live(httpClient: PrivacyHTTP(status: Self.serverErrorStatus, body: body))
    let configurations = QuotaProvider.allCases.map { provider in
      var credentials = Dictionary(uniqueKeysWithValues: provider.credentialFields.map {
        ($0.key, $0.isSecret ? Self.reflectedSecret : "fixture-account")
      })
      if provider == .devin { credentials[CredentialField.devinAPIServer] = "https://fixture.invalid" }
      return ProviderRuntimeConfiguration(provider: provider, isEnabled: true, credentials: credentials)
    }

    let snapshot = await coordinator.refresh(configurations: configurations, now: now)

    XCTAssertEqual(snapshot.failures.count, QuotaProvider.allCases.count)
    XCTAssertTrue(snapshot.providers.isEmpty)
    for failure in snapshot.failures {
      assertPrivate(failure.message)
      XCTAssertFalse(failure.message.contains(Self.responseMarker))
      XCTAssertFalse(failure.message.contains("<html>"))
      XCTAssertNil(failure.message.rangeOfCharacter(from: .controlCharacters))
      XCTAssertLessThanOrEqual(failure.message.unicodeScalars.count, Self.maximumMessageScalars)
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshotURL = directory.appendingPathComponent("snapshot.json")
    let historyURL = directory.appendingPathComponent("history.json")
    try SnapshotStore(fileURL: snapshotURL).save(snapshot)
    try QuotaHistoryStore(fileURL: historyURL).append(snapshot)
    for url in [snapshotURL, historyURL] {
      assertPrivate(try String(contentsOf: url, encoding: .utf8))
    }
  }

  func testOAuthFailureNeverExposesRefreshResponse() async {
    do {
      _ = try await ChatGPTOAuth.refresh(
        refreshToken: Self.reflectedSecret,
        httpClient: PrivacyHTTP(
          status: Self.invalidGrantStatus,
          body: "\(Self.responseMarker) \(Self.reflectedSecret) \(Self.unknownSecret)"
        )
      )
      XCTFail("Expected refresh failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .auth)
      XCTAssertEqual(error.statusCode, Self.invalidGrantStatus)
      assertPrivate(error.localizedDescription)
      XCTAssertFalse(error.message.contains(Self.responseMarker))
    } catch {
      XCTFail("Expected a public provider error")
    }
  }

  func testNonAuthOAuthFailuresOfferRetryWithoutReconnect() async {
    for status in [Self.serverErrorStatus, Self.tooManyRequestsStatus] {
      do {
        _ = try await ChatGPTOAuth.refresh(
          refreshToken: Self.reflectedSecret,
          httpClient: PrivacyHTTP(status: status, body: "\(Self.responseMarker) \(Self.reflectedSecret)")
        )
        XCTFail("Expected an API failure")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, status)
        XCTAssertTrue(error.message.contains("Try again later"))
        XCTAssertFalse(error.message.contains("Reconnect"))
        assertPrivate(error.localizedDescription)
      } catch {
        XCTFail("Expected a public provider error")
      }
    }
  }

  func testSuccessfulHTTPErrorEnvelopesKeepDetailsPrivate() async {
    let detail = "\(Self.responseMarker) \(Self.reflectedSecret) \(Self.unknownSecret)"
    let bodies: [(any QuotaProviderClient, ProviderRuntimeConfiguration)] = [
      (
        ZhipuQuotaClient(provider: .zhipu, endpoint: URL(string: "https://fixture.invalid")!,
          accountLabel: "fixture", httpClient: PrivacyHTTP(status: Self.successStatus,
            body: "{\"success\":false,\"code\":500,\"msg\":\"\(detail)\"}")),
        ProviderRuntimeConfiguration(provider: .zhipu, isEnabled: true,
          credentials: [CredentialField.zhipuAPIKey: Self.reflectedSecret])
      ),
      (
        MetaMuseQuotaClient(httpClient: PrivacyHTTP(status: Self.successStatus,
          body: "event: error\ndata: {\"type\":\"error\",\"message\":\"\(detail)\"}\n\n")),
        ProviderRuntimeConfiguration(provider: .metaMuse, isEnabled: true,
          credentials: [CredentialField.metaMuseAPIKey: Self.reflectedSecret])
      )
    ]

    for (client, configuration) in bodies {
      do {
        _ = try await client.fetchUsage(configuration: configuration, now: now)
        XCTFail("Expected an API failure")
      } catch let error as ProviderClientError {
        XCTAssertEqual(error.kind, .api)
        assertPrivate(error.localizedDescription)
        XCTAssertFalse(error.message.contains(Self.responseMarker))
      } catch {
        XCTFail("Expected a public provider error")
      }
    }
  }

  func testTransportErrorsDoNotExposeRequestDiagnostics() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PrivacyFailingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = URLSessionHTTPClient(session: session)

    do {
      _ = try await client.data(for: URLRequest(url: URL(string: "https://fixture.invalid")!))
      XCTFail("Expected a transport failure")
    } catch let error as ProviderClientError {
      XCTAssertEqual(error.kind, .network)
      assertPrivate(error.localizedDescription)
      XCTAssertFalse(error.message.contains(Self.responseMarker))
    } catch {
      XCTFail("Expected a public provider error")
    }
  }

  func testUnexpectedErrorsUsePublicMessageInsteadOfLocalizedDiagnostics() async throws {
    let coordinator = QuotaCoordinator(clients: [PrivacyFailingClient(provider: .anthropic, error: PrivacyDiagnostic())])
    let snapshot = await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])],
      now: now
    )

    let failure = try XCTUnwrap(snapshot.failures.first)
    XCTAssertEqual(failure.kind, .unknown)
    assertPrivate(failure.message)
    XCTAssertFalse(failure.message.contains(Self.responseMarker))
  }

  func testTypedFailuresRedactAllConfiguredSecretsAndBoundPublicText() async throws {
    let otherSecret = "other-account-refresh-secret"
    let message = "Reconnect \(Self.reflectedSecret) and \(otherSecret)\u{0000}\n"
      + String(repeating: "detail ", count: 200)
    let coordinator = QuotaCoordinator(clients: [
      PrivacyFailingClient(provider: .anthropic, error: ProviderClientError(kind: .auth, message: message))
    ])
    let snapshot = await coordinator.refresh(configurations: [
      ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true,
        credentials: [CredentialField.anthropicAccessToken: Self.reflectedSecret]),
      ProviderRuntimeConfiguration(provider: .openAI, isEnabled: false,
        credentials: [CredentialField.openAIRefreshToken: otherSecret])
    ], now: now)

    let failure = try XCTUnwrap(snapshot.failures.first)
    XCTAssertEqual(failure.kind, .auth)
    XCTAssertFalse(failure.message.contains(Self.reflectedSecret))
    XCTAssertFalse(failure.message.contains(otherSecret))
    XCTAssertNil(failure.message.rangeOfCharacter(from: .controlCharacters))
    XCTAssertLessThanOrEqual(failure.message.unicodeScalars.count, Self.maximumMessageScalars)
  }

  func testOverlappingSecretsAreRedactedLongestFirst() async {
    let longerSecret = Self.reflectedSecret + "-private-tail"
    let coordinator = QuotaCoordinator(clients: [
      PrivacyFailingClient(provider: .anthropic, error: ProviderClientError(kind: .auth,
        message: "Short: \(Self.reflectedSecret). Long: \(longerSecret)."))
    ])
    let snapshot = await coordinator.refresh(configurations: [
      ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true,
        credentials: [CredentialField.anthropicAccessToken: Self.reflectedSecret]),
      ProviderRuntimeConfiguration(provider: .openAI, isEnabled: false,
        credentials: [CredentialField.openAIRefreshToken: longerSecret])
    ], now: now)

    XCTAssertEqual(snapshot.failures.first?.message, "Short: [redacted]. Long: [redacted].")
  }

  func testTruncationCannotRetainAPartialSecretAtTheBoundary() async throws {
    let prefixLength = Self.reflectedSecret.count / 2
    let padding = String(repeating: "x", count: Self.maximumMessageScalars - prefixLength)
    let coordinator = QuotaCoordinator(clients: [
      PrivacyFailingClient(provider: .anthropic, error: ProviderClientError(kind: .api,
        message: padding + Self.reflectedSecret))
    ])
    let snapshot = await coordinator.refresh(configurations: [
      ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true,
        credentials: [CredentialField.anthropicAccessToken: Self.reflectedSecret])
    ], now: now)

    let failure = try XCTUnwrap(snapshot.failures.first)
    XCTAssertFalse(failure.message.contains(String(Self.reflectedSecret.prefix(prefixLength))))
    XCTAssertLessThanOrEqual(failure.message.unicodeScalars.count, Self.maximumMessageScalars)
  }

  func testNonSecretAccountMetadataIsNotRedacted() async {
    let accountID = "fixture-workspace-id"
    let message = "Check account \(accountID)."
    let coordinator = QuotaCoordinator(clients: [
      PrivacyFailingClient(provider: .openAI, error: ProviderClientError(kind: .auth, message: message))
    ])
    let snapshot = await coordinator.refresh(configurations: [
      ProviderRuntimeConfiguration(provider: .openAI, isEnabled: true,
        credentials: [CredentialField.openAIAccountID: accountID,
                      CredentialField.openAIAccessToken: Self.reflectedSecret])
    ], now: now)

    XCTAssertEqual(snapshot.failures.first?.message, message)
  }

  func testCombiningCharactersCannotBypassMessageBound() async throws {
    let message = "e" + String(repeating: "\u{0301}", count: 2_000)
    let coordinator = QuotaCoordinator(clients: [
      PrivacyFailingClient(provider: .anthropic, error: ProviderClientError(kind: .api, message: message))
    ])
    let snapshot = await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])],
      now: now
    )

    let failure = try XCTUnwrap(snapshot.failures.first)
    XCTAssertLessThanOrEqual(failure.message.unicodeScalars.count, Self.maximumMessageScalars)
  }

  func testSafeRecoveryAdviceIsPreserved() async throws {
    let message = "Reconnect this account or import its credentials again."
    let coordinator = QuotaCoordinator(clients: [
      PrivacyFailingClient(provider: .anthropic, error: ProviderClientError(kind: .auth, message: message))
    ])
    let snapshot = await coordinator.refresh(
      configurations: [ProviderRuntimeConfiguration(provider: .anthropic, isEnabled: true, credentials: [:])],
      now: now
    )

    XCTAssertEqual(snapshot.failures.first?.message, message)
  }

  private func assertPrivate(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(text.contains(Self.reflectedSecret), file: file, line: line)
    XCTAssertFalse(text.contains(Self.unknownSecret), file: file, line: line)
    XCTAssertFalse(text.contains(Self.responseMarker), file: file, line: line)
  }
}

private struct PrivacyHTTP: HTTPClient {
  let status: Int
  let body: String

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

private struct PrivacyFailingClient: QuotaProviderClient {
  let provider: QuotaProvider
  let error: any Error & Sendable

  func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    throw error
  }
}

private struct PrivacyDiagnostic: LocalizedError, Sendable {
  var errorDescription: String? {
    "\(FailurePrivacyTests.responseMarker) \(FailurePrivacyTests.reflectedSecret) \(FailurePrivacyTests.unknownSecret)"
  }
}

private final class PrivacyFailingURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: NSError(
      domain: NSURLErrorDomain,
      code: URLError.timedOut.rawValue,
      userInfo: [NSLocalizedDescriptionKey: PrivacyDiagnostic().errorDescription!]
    ))
  }

  override func stopLoading() {}
}
