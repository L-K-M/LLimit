import Foundation
import WebKit
import QuotaCore

@MainActor
final class VeniceWebBrowser: NSObject, WKNavigationDelegate {
  enum Failure: LocalizedError {
    case signedOut, wrongAccount, unavailable, invalidResponse

    var errorDescription: String? {
      switch self {
      case .signedOut: return "Sign in to Venice in this window, then try again."
      case .wrongAccount: return "Venice switched accounts. Reconnect with the Venice account you want to track."
      case .unavailable: return "Could not reach Venice’s web dashboard. Try again."
      case .invalidResponse: return "Venice’s web dashboard returned unreadable usage."
      }
    }

    var refreshError: ProviderClientError {
      switch self {
      case .signedOut, .wrongAccount:
        return ProviderClientError(kind: .auth, message: "Reconnect the Venice web account in LLimit Settings.")
      case .unavailable:
        return ProviderClientError(kind: .network, message: "Venice’s web dashboard is unavailable.")
      case .invalidResponse:
        return ProviderClientError(kind: .decoding, message: "Venice’s web dashboard returned unreadable usage.")
      }
    }
  }

  struct Reading: Decodable {
    let userID: String
    let subscription: VeniceWebSubscription?
  }

  private struct Reply: Decodable {
    let status: String
    let reading: Reading?
  }

  let webView: WKWebView
  private let interactive: Bool
  private var pending: CheckedContinuation<Reading, Error>?
  private var requestID: UUID?
  private var timeout: Task<Void, Never>?
  private var readTask: Task<Void, Never>?

  init(profileID: UUID, interactive: Bool) {
    self.interactive = interactive
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileID)
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    webView.navigationDelegate = self
    let path = interactive ? "/sign-in?redirect_url=%2Fsettings%2Fapi" : "/settings/api"
    webView.load(URLRequest(url: URL(string: "https://venice.ai" + path)!))
  }

  func read() async throws -> Reading {
    try Task.checkCancellation()
    guard pending == nil else { throw Failure.unavailable }
    let requestID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.requestID = requestID
        pending = continuation
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(25)) } catch { return }
          self?.finish(.failure(Failure.unavailable), requestID: requestID)
        }
        readTask = Task { [weak self] in
          await self?.readPage(requestID: requestID)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(.failure(CancellationError()), requestID: requestID)
      }
    }
  }

  static func removeProfile(_ id: UUID) async -> Bool {
    // Initialize WebKit before removing a profile in a process that has not
    // opened any web view yet, such as disconnecting a disabled account.
    _ = WKWebsiteDataStore.nonPersistent()
    // The sheet can retain the old view through its dismissal animation.
    for delay in [Duration.milliseconds(400), .seconds(2)] {
      do {
        try await Task.sleep(for: delay)
        try await WKWebsiteDataStore.remove(forIdentifier: id)
        return true
      } catch {}
    }
    return false
  }

  func stop() {
    if let requestID { finish(.failure(CancellationError()), requestID: requestID) }
    webView.stopLoading()
  }

  private func readPage(requestID: UUID) async {
    do {
      while webView.isLoading || webView.url == nil {
        try await Task.sleep(for: .milliseconds(150))
      }
      guard webView.url?.host == "venice.ai" else { throw Failure.signedOut }
      let value = try await webView.callAsyncJavaScript(Self.sessionScript, arguments: [:], in: nil, contentWorld: .page)
      guard let json = value as? String, let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else {
        throw Failure.invalidResponse
      }
      switch reply.status {
      case "ok":
        guard let reading = reply.reading, !reading.userID.isEmpty else { throw Failure.invalidResponse }
        finish(.success(reading), requestID: requestID)
      case "signedOut": throw Failure.signedOut
      case "wrongAccount": throw Failure.wrongAccount
      case "unavailable": throw Failure.unavailable
      default: throw Failure.invalidResponse
      }
    } catch let failure as Failure {
      finish(.failure(failure), requestID: requestID)
    } catch {
      finish(.failure(Failure.unavailable), requestID: requestID)
    }
  }

  private func finish(_ result: Result<Reading, Error>, requestID: UUID) {
    guard self.requestID == requestID else { return }
    let continuation = pending
    pending = nil
    self.requestID = nil
    timeout?.cancel()
    timeout = nil
    readTask?.cancel()
    readTask = nil
    continuation?.resume(with: result)
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let frame = action.targetFrame else { return .cancel }
    guard frame.isMainFrame else { return .allow }
    guard let url = action.request.url, url.scheme == "https", url.port == nil,
          url.user == nil, url.password == nil, let host = url.host else { return .cancel }
    if host == "venice.ai" { return .allow }
    if interactive && ["clerk.venice.ai", "accounts.google.com", "appleid.apple.com"].contains(host) { return .allow }
    return .cancel
  }

  // Both tokens remain in the trusted page context. Only the pinned user ID and
  // allowlisted quota values cross into Swift. Clerk renews its own session.
  static let sessionScript = #"""
    const reply = (status, reading) => JSON.stringify({ status, reading });
    if (window.location.origin !== "https://venice.ai") return reply("signedOut");

    for (let attempt = 0; attempt < 48; attempt++) {
      const clerk = window.Clerk;
      if (clerk?.loaded || clerk?.status === "ready" || clerk?.status === "degraded") break;
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    const clerk = window.Clerk;
    if (!clerk?.loaded && clerk?.status !== "ready" && clerk?.status !== "degraded") {
      return reply("unavailable");
    }
    const session = clerk.session;
    if (!session?.user?.id) return reply("signedOut");

    try {
      const bearer = await session.getToken({ skipCache: true });
      if (!bearer) return reply("signedOut");
      const response = await fetch("https://outerface.venice.ai/api/user/session?bustBalanceCache=true", {
        method: "GET", headers: { Authorization: "Bearer " + bearer, Accept: "application/json" },
        credentials: "omit", redirect: "error", cache: "no-store", signal: AbortSignal.timeout(9000)
      });
      if (response.status === 401 || response.status === 403) return reply("signedOut");
      if (!response.ok) return reply("unavailable");

      const body = await response.json();
      const encoded = typeof body.token === "string" ? body.token.split(".") : [];
      if (encoded.length !== 3) return reply("invalidResponse");
      const base64 = encoded[1].replace(/-/g, "+").replace(/_/g, "/");
      const bytes = Uint8Array.from(atob(base64), character => character.charCodeAt(0));
      const claims = JSON.parse(new TextDecoder().decode(bytes));
      if (clerk.session?.id !== session.id ||
          (claims.clerkUserId != null && claims.clerkUserId !== session.user.id)) return reply("wrongAccount");
      if (typeof claims.authSystemUserId !== "string" || !claims.authSystemUserId.trim()) {
        return reply("invalidResponse");
      }

      const usage = claims.bundledCreditsUsage;
      const subscription = usage == null ? null : {
        availableCredits: usage.availableCredits ?? claims.bundledCredits,
        usedThisCycle: usage.usedThisCycle,
        monthlyRefillCredits: usage.monthlyRefillCredits,
        nextRefillAt: usage.nextRefillAt
      };
      return reply("ok", { userID: claims.authSystemUserId, subscription });
    } catch {
      return reply("unavailable");
    }
    """#
}
