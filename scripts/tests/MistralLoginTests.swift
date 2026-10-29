import AppKit
import Foundation
import WebKit
import QuotaCore

/// Offline integration uses only temporary stores and synthetic credentials.
@main
struct MistralLoginTests {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let blank = URL(string: "about:blank")!
    var callbacks = 0
    let first = MistralLoginSession(accountID: "first", startURL: blank) { _, _ in callbacks += 1 }
    let second = MistralLoginSession(accountID: "second", startURL: blank) { _, _ in callbacks += 1 }
    defer { first.cancel(); second.cancel() }
    let firstStore = first.webView.configuration.websiteDataStore
    let secondStore = second.webView.configuration.websiteDataStore
    precondition(!firstStore.isPersistent && !secondStore.isPersistent)
    precondition(firstStore !== secondStore, "Each account must own a separate temporary browser")
    seed([cookie("ory_session_fixture", "first-session")], in: first)
    loadFixture(in: first)
    var firstCookies: [HTTPCookie]?
    var secondCookies: [HTTPCookie]?
    firstStore.httpCookieStore.getAllCookies { firstCookies = $0 }
    secondStore.httpCookieStore.getAllCookies { secondCookies = $0 }
    wait(until: { firstCookies != nil && secondCookies != nil })
    precondition(firstCookies?.contains(where: { $0.name == "ory_session_fixture" }) == true)
    precondition(secondCookies?.isEmpty == true, "One account cannot inherit another account's login")
    first.cancel()
    first.connect()
    second.connect()
    precondition(callbacks == 0 && !first.isConnecting && !second.isConnecting)
    precondition(second.message.contains("Finish signing in"))

    var connected: (UUID, MistralBrowserSession)?
    var connectionCallbacks = 0
    let signedIn = MistralLoginSession(accountID: "signed-in", startURL: blank) { attemptID, session in
      connectionCallbacks += 1
      connected = (attemptID, session)
    }
    defer { signedIn.cancel() }
    seed([
      cookie("ory_session_fixture", "owned-session"),
      cookie("csrftoken", "owned-csrf", httpOnly: false),
      cookie("analytics_id", "excluded-analytics"),
      cookie("ory_session_foreign", "excluded-auth-origin", domain: "v2.auth.mistral.ai"),
      cookie("sso_token", "excluded-sso", domain: "v2.auth.mistral.ai")
    ], in: signedIn)
    loadFixture(in: signedIn)
    signedIn.connect()
    wait(until: { !signedIn.isConnecting })
    precondition(connectionCallbacks == 1 && connected?.0 == signedIn.id)
    let browser = connected!.1
    precondition(browser.cookieHeader.contains("ory_session_fixture=owned-session"))
    precondition(!browser.cookieHeader.contains("excluded"), "Only the Admin authentication allowlist can be saved")
    let encoded = try browser.encoded()
    precondition(!encoded.contains("excluded"))
    let credentials = try browser.credentials(userID: "fixture-user", organizationID: "fixture-organization")
    precondition(credentials[CredentialField.mistralUserID] == "fixture-user")
    precondition(credentials[CredentialField.mistralOrganizationID] == "fixture-organization")
    precondition(credentials[CredentialField.mistralBrowserSession] == encoded)

    // An auth page is navigable but cannot be adopted as a subscription login.
    var wrongOriginCallbacks = 0
    let wrongOrigin = MistralLoginSession(accountID: "wrong-origin", startURL: blank) { _, _ in
      wrongOriginCallbacks += 1
    }
    defer { wrongOrigin.cancel() }
    seed([cookie("ory_session_fixture", "wrong-origin-session")], in: wrongOrigin)
    let authURL = URL(string: "https://v2.auth.mistral.ai/login")!
    precondition(MistralSignInPolicy.allowsNavigation(to: authURL))
    loadFixture(in: wrongOrigin, origin: authURL)
    wrongOrigin.connect()
    precondition(!wrongOrigin.isConnecting && wrongOriginCallbacks == 0)
    precondition(wrongOrigin.message.contains("Finish signing in"))

    // A rendered Admin origin alone is insufficient without an authentication cookie.
    var missingCookieCallbacks = 0
    let missingCookie = MistralLoginSession(accountID: "missing-cookie", startURL: blank) { _, _ in
      missingCookieCallbacks += 1
    }
    defer { missingCookie.cancel() }
    seed([cookie("analytics_id", "analytics-only")], in: missingCookie)
    loadFixture(in: missingCookie)
    missingCookie.connect()
    wait(until: { !missingCookie.isConnecting })
    precondition(missingCookieCallbacks == 0)

    // Cancellation before cookie enumeration finishes cannot invoke verification.
    var cancelledCallbacks = 0
    let cancelled = MistralLoginSession(accountID: "cancelled", startURL: blank) { _, _ in
      cancelledCallbacks += 1
    }
    defer { cancelled.cancel() }
    seed([cookie("ory_session_fixture", "cancelled-session")], in: cancelled)
    loadFixture(in: cancelled)
    cancelled.connect()
    cancelled.cancel()
    wait(until: { !cancelled.isConnecting })
    precondition(cancelledCallbacks == 0)
    precondition(cancelled.webView.navigationDelegate == nil && cancelled.webView.uiDelegate == nil)

    // Cancellation while asynchronous verification awaits prevents a subsequent save.
    var asyncCallbacks = 0
    var saved = false
    var finished = false
    let asyncCancelled = MistralLoginSession(accountID: "async-cancelled", startURL: blank) { _, _ in
      asyncCallbacks += 1
      defer { finished = true }
      try await Task.sleep(for: .seconds(2))
      try Task.checkCancellation()
      saved = true
    }
    defer { asyncCancelled.cancel() }
    seed([cookie("ory_session_fixture", "async-session")], in: asyncCancelled)
    loadFixture(in: asyncCancelled)
    asyncCancelled.connect()
    wait(until: { asyncCallbacks == 1 })
    asyncCancelled.connect()
    precondition(asyncCallbacks == 1, "Repeated clicks must not create concurrent connection attempts")
    asyncCancelled.cancel()
    wait(until: { finished && !asyncCancelled.isConnecting })
    precondition(asyncCallbacks == 1 && !saved)

    var rejectedCallbacks = 0
    let rejected = MistralLoginSession(accountID: "rejected", startURL: blank) { _, _ in
      rejectedCallbacks += 1
      throw ProviderClientError(kind: .auth, message: "Mistral requires a new sign-in.")
    }
    defer { rejected.cancel() }
    seed([cookie("ory_session_fixture", "rejected-session")], in: rejected)
    loadFixture(in: rejected)
    rejected.connect()
    wait(until: { !rejected.isConnecting })
    precondition(rejectedCallbacks == 1 && rejected.message == "Mistral requires a new sign-in.")
    precondition(!rejected.message.contains("rejected-session"))

    print("Mistral WebKit isolation, cookie capture, origin, verification, and cancellation checks passed")
  }

  private static func cookie(_ name: String, _ value: String, domain: String = ".mistral.ai",
                             httpOnly: Bool = true) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"
    ]
    if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    return HTTPCookie(properties: properties)!
  }

  @MainActor private static func seed(_ cookies: [HTTPCookie], in session: MistralLoginSession) {
    for cookie in cookies {
      var stored = false
      session.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
  }

  @MainActor private static func loadFixture(in session: MistralLoginSession,
                                             origin: URL = MistralSignInPolicy.startURL) {
    session.webView.loadHTMLString("<html><body>Offline subscription fixture</body></html>", baseURL: origin)
    wait(until: { session.webView.url == origin && !session.webView.isLoading })
  }

  @MainActor private static func wait(until complete: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !complete(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(complete(), "WebKit did not complete the offline operation within 15 seconds")
  }
}
