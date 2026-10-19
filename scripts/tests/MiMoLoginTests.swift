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
    print("MiMo WebKit isolation, HttpOnly capture, cancellation, and origin checks passed")
  }

  @MainActor private static func wait(until complete: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !complete(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(complete(), "WebKit did not complete the offline cookie operation")
  }
}
