import AppKit
import Foundation
import WebKit
import QuotaCore

/// Offline WebKit integration. Only ephemeral stores and fixture cookies are
/// touched; the production console and the user's browsers are never opened.
@main
struct MiMoLoginTests {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let blank = URL(string: "about:blank")!
    var callbacks = 0
    let first = MiMoLoginSession(accountID: "first", startURL: blank) { _, _ in callbacks += 1 }
    let second = MiMoLoginSession(accountID: "second", startURL: blank) { _, _ in callbacks += 1 }
    defer { first.cancel(); second.cancel() }
    let firstStore = first.webView.configuration.websiteDataStore
    let secondStore = second.webView.configuration.websiteDataStore
    precondition(!firstStore.isPersistent && !secondStore.isPersistent)
    precondition(firstStore !== secondStore, "Accounts must own separate browser stores")

    let origin = MiMoSignInPolicy.startURL
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: [
      "Set-Cookie": "api-platform_serviceToken=offline-fixture; Secure; HttpOnly; Path=/; Domain=platform.xiaomimimo.com"
    ], for: origin)
    precondition(cookies.count == 1 && cookies[0].isHTTPOnly)
    var stored = false
    firstStore.httpCookieStore.setCookie(cookies[0]) { stored = true }
    wait(until: { stored })
    var firstCookies: [HTTPCookie]?
    var secondCookies: [HTTPCookie]?
    firstStore.httpCookieStore.getAllCookies { firstCookies = $0 }
    secondStore.httpCookieStore.getAllCookies { secondCookies = $0 }
    wait(until: { firstCookies != nil && secondCookies != nil })
    precondition(firstCookies?.contains(where: { $0.name == "api-platform_serviceToken" }) == true)
    precondition(secondCookies?.isEmpty == true, "One login must not inherit another login's cookies")

    first.cancel()
    first.connect()
    second.connect() // about:blank cannot supply a platform login.
    precondition(callbacks == 0 && !first.isConnecting && !second.isConnecting)
    precondition(second.message.contains("Finish signing in"))

    var connected: (attemptID: UUID, cookies: MiMoBrowserLogin)?
    var connectionCallbacks = 0
    let signedIn = MiMoLoginSession(accountID: "signed-in", startURL: blank) { attemptID, cookies in
      connectionCallbacks += 1
      connected = (attemptID, cookies)
    }
    defer { signedIn.cancel() }
    let signedInStore = signedIn.webView.configuration.websiteDataStore
    let fixtureProperties: [[HTTPCookiePropertyKey: String]] = [
      [.name: "api-platform_serviceToken", .value: "\"offline-token\"", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "api-platform_serviceToken", .value: "\"offline-token\"", .domain: ".platform.xiaomimimo.com", .path: "/api/v1/tokenPlan"],
      [.name: "api-platform_slh", .value: "\"offline-slh\"", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "api-platform_ph", .value: "\"offline-ph\"", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "userId", .value: "offline-user", .domain: ".xiaomimimo.com", .path: "/"],
      [.name: "userId", .value: "offline-user", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "xiaomi_passport", .value: "excluded-sso", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "analytics_id", .value: "excluded-analytics", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "userId", .value: "offline-user", .domain: ".account.xiaomi.com", .path: "/"],
      [.name: "passToken", .value: "offline-sso", .domain: ".account.xiaomi.com", .path: "/"],
    ]
    for properties in fixtureProperties {
      let cookie = HTTPCookie(properties: properties)!
      precondition(!cookie.isSecure, "The Secure flag must not be required for HTTPS console adoption")
      var stored = false
      signedInStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
    // Supplying an HTTPS base establishes the real production origin guard
    // without loading a remote page or weakening the navigation policy.
    signedIn.webView.loadHTMLString("<html><body>Offline console fixture</body></html>", baseURL: origin)
    wait(until: { signedIn.webView.url == origin && !signedIn.webView.isLoading })
    signedIn.connect()
    wait(until: { !signedIn.isConnecting })
    precondition(connectionCallbacks == 1, "Connect must adopt the signed-in attempt's browser cookies")
    precondition(connected?.attemptID == signedIn.id)
    precondition(connected?.cookies.console.userID == "offline-user")
    precondition(connected?.cookies.console.header == "api-platform_serviceToken=\"offline-token\"; api-platform_slh=\"offline-slh\"; api-platform_ph=\"offline-ph\"; userId=offline-user")
    precondition(connected?.cookies.browser?.matches(connected!.cookies.console) == true)
    // A connected console alone must not be reported as an automatically
    // renewable browser login. The manual Cookie field remains available.
    let consoleOnly = MiMoLoginSession(accountID: "console-only", startURL: blank) { _, _ in
      preconditionFailure("Browser sign-in requires a saved Xiaomi login")
    }
    defer { consoleOnly.cancel() }
    for item in [cookie("api-platform_serviceToken", "fixture", domain: ".platform.xiaomimimo.com"),
                 cookie("userId", "offline-user", domain: ".xiaomimimo.com")] {
      var stored = false
      consoleOnly.webView.configuration.websiteDataStore.httpCookieStore.setCookie(item) { stored = true }
      wait(until: { stored })
    }
    consoleOnly.webView.loadHTMLString("<html>Console only</html>", baseURL: origin)
    wait(until: { consoleOnly.webView.url == origin && !consoleOnly.webView.isLoading })
    consoleOnly.connect()
    wait(until: { !consoleOnly.isConnecting })
    precondition(consoleOnly.message.contains("saved login"))
    try testRenewal()
    print("MiMo WebKit isolation, login, renewal, identity, timeout, and cancellation checks passed")
  }

  @MainActor private static func testRenewal() throws {
    let blank = URL(string: "about:blank")!
    let browser = try MiMoBrowserSession(cookies: [
      cookie("userId", "offline-user", domain: ".account.xiaomi.com"),
      cookie("passToken", "offline-sso", domain: ".account.xiaomi.com")
    ], userID: "offline-user")
    for identity in ["offline-user", "different-user"] {
      let renewal = MiMoSessionRenewal(browser: browser, startURL: blank, timeout: 15)
      var result: Result<MiMoBrowserLogin, Error>?
      Task { @MainActor in
        do { result = .success(try await renewal.renew()) }
        catch { result = .failure(error) }
      }
      wait(until: { renewal.webView.url == blank && !renewal.webView.isLoading })
      let store = renewal.webView.configuration.websiteDataStore.httpCookieStore
      var seeded: [HTTPCookie]?
      store.getAllCookies { seeded = $0 }
      wait(until: { seeded != nil })
      precondition(Set(seeded!.map(\.name)) == ["userId", "passToken"], "Do not seed old platform cookies or analytics")
      precondition(!renewal.webView.configuration.websiteDataStore.isPersistent)
      for cookie in [
        cookie("api-platform_serviceToken", "fresh-console", domain: ".platform.xiaomimimo.com"),
        cookie("userId", identity, domain: ".xiaomimimo.com"),
        cookie("analytics_id", "excluded", domain: ".account.xiaomi.com")
      ] {
        var stored = false
        store.setCookie(cookie) { stored = true }
        wait(until: { stored })
      }
      renewal.webView.loadHTMLString("<html><body>Renewed console fixture</body></html>", baseURL: MiMoSignInPolicy.startURL)
      wait(until: { result != nil })
      if identity == "offline-user" {
        let login = try result!.get()
        precondition(login.console.header == "api-platform_serviceToken=fresh-console; userId=offline-user")
        precondition(login.browser?.matches(login.console) == true)
        let stored = try login.browser!.encoded()
        precondition(!stored.contains("analytics"))
      } else {
        guard case .failure(let error)? = result else { preconditionFailure("A renewal must not switch accounts") }
        precondition((error as? ProviderClientError)?.kind == .auth)
        precondition(!error.localizedDescription.contains("different-user"))
      }
      precondition(renewal.webView.navigationDelegate == nil)
    }

    let timedOut = MiMoSessionRenewal(browser: browser, startURL: blank, timeout: 0.05)
    var timeoutError: Error?
    Task { @MainActor in
      do { _ = try await timedOut.renew(); preconditionFailure("Expected timeout") }
      catch { timeoutError = error }
    }
    wait(until: { timeoutError != nil })
    precondition((timeoutError as? ProviderClientError)?.kind == .auth)
    precondition(timedOut.webView.navigationDelegate == nil)

    let cancelled = MiMoSessionRenewal(browser: browser, startURL: blank, timeout: 15)
    var cancellationError: Error?
    let task = Task { @MainActor in
      do { _ = try await cancelled.renew(); preconditionFailure("Expected cancellation") }
      catch { cancellationError = error }
    }
    wait(until: { cancelled.webView.url == blank })
    task.cancel()
    wait(until: { cancellationError != nil })
    precondition(cancellationError is CancellationError)
    precondition(cancelled.webView.navigationDelegate == nil)
  }

  private static func cookie(_ name: String, _ value: String, domain: String) -> HTTPCookie {
    HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
                           HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
  }

  @MainActor private static func wait(until complete: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !complete(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(complete(), "WebKit did not complete the offline cookie operation")
  }
}
