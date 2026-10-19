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

    var connected: (attemptID: UUID, cookies: MiMoSessionCookies)?
    var connectionCallbacks = 0
    let signedIn = MiMoLoginSession(accountID: "signed-in", startURL: blank) { attemptID, cookies in
      connectionCallbacks += 1
      connected = (attemptID, cookies)
    }
    defer { signedIn.cancel() }
    let signedInStore = signedIn.webView.configuration.websiteDataStore
    let fixtureProperties: [[HTTPCookiePropertyKey: String]] = [
      [.name: "api-platform_serviceToken", .value: "offline-token", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "api-platform_serviceToken", .value: "offline-token", .domain: ".platform.xiaomimimo.com", .path: "/api/v1/tokenPlan"],
      [.name: "userId", .value: "offline-user", .domain: ".xiaomimimo.com", .path: "/"],
      [.name: "userId", .value: "offline-user", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "xiaomi_passport", .value: "excluded-sso", .domain: ".platform.xiaomimimo.com", .path: "/"],
      [.name: "analytics_id", .value: "excluded-analytics", .domain: ".platform.xiaomimimo.com", .path: "/"],
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
    precondition(connected?.cookies.userID == "offline-user")
    precondition(connected?.cookies.header == "api-platform_serviceToken=offline-token; userId=offline-user")
    print("MiMo WebKit isolation, cookie adoption, filtering, cancellation, and origin checks passed")
  }

  @MainActor private static func wait(until complete: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !complete(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(complete(), "WebKit did not complete the offline cookie operation")
  }
}
