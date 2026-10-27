import AppKit
import Foundation
import WebKit
import QuotaCore

/// Offline WebKit integration. Only ephemeral stores and fixture cookies are
/// touched; the production console and the user's browsers are never opened.
@main
struct StepFunLoginTests {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let blank = URL(string: "about:blank")!
    var callbacks = 0
    let first = StepFunLoginSession(accountID: "first", startURL: blank) { _, _ in callbacks += 1 }
    let second = StepFunLoginSession(accountID: "second", startURL: blank) { _, _ in callbacks += 1 }
    defer { first.cancel(); second.cancel() }
    let firstStore = first.webView.configuration.websiteDataStore
    let secondStore = second.webView.configuration.websiteDataStore
    precondition(!firstStore.isPersistent && !secondStore.isPersistent)
    precondition(firstStore !== secondStore, "Accounts must own separate browser stores")

    let origin = StepFunSignInPolicy.startURL
    // Seed a fixture cookie into the first session's store
    let fixtureCookie = makeCookie(name: "Oasis-Token", value: "dummy...dummy", domain: "platform.stepfun.ai", path: "/")
    var stored = false
    firstStore.httpCookieStore.setCookie(fixtureCookie) { stored = true }
    wait(until: { stored })
    var firstCookies: [HTTPCookie]?
    var secondCookies: [HTTPCookie]?
    firstStore.httpCookieStore.getAllCookies { firstCookies = $0 }
    secondStore.httpCookieStore.getAllCookies { secondCookies = $0 }
    wait(until: { firstCookies != nil && secondCookies != nil })
    precondition(firstCookies?.contains(where: { $0.name == "Oasis-Token" }) == true)
    precondition(secondCookies?.isEmpty == true, "One login must not inherit another login's cookies")

    // Cancelled session cannot connect; about:blank cannot connect
    first.cancel()
    first.connect()
    second.connect()
    precondition(callbacks == 0 && !first.isConnecting && !second.isConnecting)
    precondition(second.message.contains("Finish signing in"))

    // --- Successful synthetic console connect ---
    var connected: (attemptID: UUID, session: StepFunBrowserSession)?
    var connectionCallbacks = 0
    let signedIn = StepFunLoginSession(accountID: "signed-in", startURL: blank) { attemptID, session in
      connectionCallbacks += 1
      connected = (attemptID, session)
    }
    defer { signedIn.cancel() }
    let signedInStore = signedIn.webView.configuration.websiteDataStore

    // Build synthetic unsigned fixture JWTs
    let accessJWT = unsignedJWT(claims: ["mode": 2, "oasis_id": 123, "exp": Int(Date().timeIntervalSince1970 + 3600)])
    let refreshJWT = unsignedJWT(claims: ["app_id": 20700, "device_id": "offline-device", "oasis_id": 123, "exp": Int(Date().timeIntervalSince1970 + 3600)])

    // Seed console cookies: Oasis-Token (compound) and Oasis-Webid
    let oasisToken = makeCookie(name: "Oasis-Token", value: "\(accessJWT)...\(refreshJWT)", domain: "platform.stepfun.ai", path: "/")
    let oasisWebid = makeCookie(name: "Oasis-Webid", value: "offline-device", domain: "platform.stepfun.ai", path: "/")
    for cookie in [oasisToken, oasisWebid] {
      precondition(cookie.isHTTPOnly)
      precondition(!cookie.isSecure, "The Secure flag must not be required for HTTPS console adoption")
      var stored = false
      signedInStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
    // Seed cookies that should be excluded by encoded()
    let analyticsCookie = makeCookie(name: "analytics_id", value: "excluded-analytics", domain: "platform.stepfun.ai", path: "/")
    stored = false
    signedInStore.httpCookieStore.setCookie(analyticsCookie) { stored = true }
    wait(until: { stored })
    let ssoCookie = makeCookie(name: "sso_token", value: "excluded-sso", domain: "account.stepfun.ai", path: "/")
    stored = false
    signedInStore.httpCookieStore.setCookie(ssoCookie) { stored = true }
    wait(until: { stored })
    let foreignAuth = makeCookie(name: "Oasis-Token", value: "excluded-foreign-auth", domain: "account.stepfun.ai", path: "/")
    stored = false
    signedInStore.httpCookieStore.setCookie(foreignAuth) { stored = true }
    wait(until: { stored })

    // Load local origin page to establish production console origin
    signedIn.webView.loadHTMLString("<html><body>Offline console fixture</body></html>", baseURL: origin)
    wait(until: { signedIn.webView.url == origin && !signedIn.webView.isLoading })
    signedIn.connect()
    wait(until: { !signedIn.isConnecting })
    precondition(connectionCallbacks == 1, "Connect must adopt the signed-in attempt's browser cookies")
    precondition(connected?.attemptID == signedIn.id)
    precondition(connected?.session.subject == "123")
    precondition(connected?.session.webID == "offline-device")
    precondition(connected?.session.accessToken == accessJWT)

    // encoded() must exclude analytics_id, sso_token, and the SSO domain cookies
    let encoded = try connected!.session.encoded()
    precondition(!encoded.contains("analytics"), "encoded() must exclude analytics cookies")
    precondition(!encoded.contains("excluded-sso"), "encoded() must exclude SSO cookie values")
    precondition(!encoded.contains("sso_token"), "encoded() must exclude SSO cookie names")
    precondition(!encoded.contains("excluded-foreign-auth"), "Authentication cookies from another host must not be adopted")
    // Verify exactly two auth record names (Oasis-Token and Oasis-Webid)
    let encodedData = Data(encoded.utf8)
    let records = try! JSONSerialization.jsonObject(with: encodedData, options: []) as! [[String: Any]]
    let recordNames = records.compactMap { $0["name"] as? String }
    precondition(recordNames.count == 2, "encoded() must produce exactly two auth records, got \(recordNames.count)")
    precondition(Set(recordNames) == ["Oasis-Token", "Oasis-Webid"], "encoded() must contain only Oasis-Token and Oasis-Webid")

    // --- Wrong origin cannot connect ---
    var wrongOriginCallbacks = 0
    let wrongOrigin = StepFunLoginSession(accountID: "wrong-origin", startURL: blank) { _, _ in
      wrongOriginCallbacks += 1
    }
    defer { wrongOrigin.cancel() }
    let wrongOriginURL = URL(string: "https://account.stepfun.ai/login")!
    precondition(StepFunSignInPolicy.allowsNavigation(to: wrongOriginURL), "account.stepfun.ai is allowlisted for navigation")
    let wrongStore = wrongOrigin.webView.configuration.websiteDataStore
    let wrongToken = makeCookie(name: "Oasis-Token", value: "\(accessJWT)...\(refreshJWT)", domain: "platform.stepfun.ai", path: "/")
    let wrongWebid = makeCookie(name: "Oasis-Webid", value: "offline-device", domain: "platform.stepfun.ai", path: "/")
    for cookie in [wrongToken, wrongWebid] {
      var stored = false
      wrongStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
    wrongOrigin.webView.loadHTMLString("<html><body>Wrong origin</body></html>", baseURL: wrongOriginURL)
    wait(until: { wrongOrigin.webView.url == wrongOriginURL && !wrongOrigin.webView.isLoading })
    wrongOrigin.connect()
    wait(until: { !wrongOrigin.isConnecting })
    precondition(wrongOriginCallbacks == 0, "Wrong origin must not trigger callback")

    // --- Anonymous access (mode 1) rejected ---
    var anonymousCallbacks = 0
    let anonymous = StepFunLoginSession(accountID: "anonymous", startURL: blank) { _, _ in
      anonymousCallbacks += 1
    }
    defer { anonymous.cancel() }
    let anonStore = anonymous.webView.configuration.websiteDataStore
    let anonAccessJWT = unsignedJWT(claims: ["mode": 1, "oasis_id": 999, "exp": Int(Date().timeIntervalSince1970 + 3600)])
    let anonRefreshJWT = unsignedJWT(claims: ["app_id": 20700, "device_id": "anon-device", "oasis_id": 999, "exp": Int(Date().timeIntervalSince1970 + 3600)])
    let anonToken = makeCookie(name: "Oasis-Token", value: "\(anonAccessJWT)...\(anonRefreshJWT)", domain: "platform.stepfun.ai", path: "/")
    let anonWebid = makeCookie(name: "Oasis-Webid", value: "anon-device", domain: "platform.stepfun.ai", path: "/")
    for cookie in [anonToken, anonWebid] {
      var stored = false
      anonStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
    anonymous.webView.loadHTMLString("<html><body>Anonymous fixture</body></html>", baseURL: origin)
    wait(until: { anonymous.webView.url == origin && !anonymous.webView.isLoading })
    anonymous.connect()
    wait(until: { !anonymous.isConnecting })
    precondition(anonymousCallbacks == 0, "Anonymous access mode must not trigger callback")

    // --- Cancellation while cookie enumeration awaits ---
    var cancelAwaitCallbacks = 0
    let cancelAwait = StepFunLoginSession(accountID: "cancel-await", startURL: blank) { _, _ in
      cancelAwaitCallbacks += 1
    }
    defer { cancelAwait.cancel() }
    let cancelStore = cancelAwait.webView.configuration.websiteDataStore
    let cancelToken = makeCookie(name: "Oasis-Token", value: "\(accessJWT)...\(refreshJWT)", domain: "platform.stepfun.ai", path: "/")
    let cancelWebid = makeCookie(name: "Oasis-Webid", value: "offline-device", domain: "platform.stepfun.ai", path: "/")
    for cookie in [cancelToken, cancelWebid] {
      var stored = false
      cancelStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
    cancelAwait.webView.loadHTMLString("<html><body>Cancel await fixture</body></html>", baseURL: origin)
    wait(until: { cancelAwait.webView.url == origin && !cancelAwait.webView.isLoading })
    // Cancel immediately after connect while cookie enumeration awaits
    cancelAwait.connect()
    cancelAwait.cancel()
    // Drain RunLoop briefly to verify callback is not merely an immediate sample
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    precondition(cancelAwaitCallbacks == 0, "Cancelled session must not invoke callback")

    // --- Async cancellation: Task.checkCancellation throws before simulated save ---
    var asyncCancelCallbacks = 0
    var asyncCancelSaved = false
    let asyncCancel = StepFunLoginSession(accountID: "async-cancel", startURL: blank) { _, _ in
      asyncCancelCallbacks += 1
      // Simulate slow save with Task.sleep so cancellation can fire first
      try await Task.sleep(for: .seconds(2))
      try Task.checkCancellation()
      asyncCancelSaved = true
    }
    defer { asyncCancel.cancel() }
    let asyncCancelStore = asyncCancel.webView.configuration.websiteDataStore
    let asyncToken = makeCookie(name: "Oasis-Token", value: "\(accessJWT)...\(refreshJWT)", domain: "platform.stepfun.ai", path: "/")
    let asyncWebid = makeCookie(name: "Oasis-Webid", value: "offline-device", domain: "platform.stepfun.ai", path: "/")
    for cookie in [asyncToken, asyncWebid] {
      var stored = false
      asyncCancelStore.httpCookieStore.setCookie(cookie) { stored = true }
      wait(until: { stored })
    }
    asyncCancel.webView.loadHTMLString("<html><body>Async cancel fixture</body></html>", baseURL: origin)
    wait(until: { asyncCancel.webView.url == origin && !asyncCancel.webView.isLoading })
    asyncCancel.connect()
    // Wait for the callback to enter (so its sleep starts), then cancel
    wait(until: { asyncCancelCallbacks == 1 })
    asyncCancel.cancel()
    wait(until: { !asyncCancel.isConnecting })
    // Callback entered exactly once; cancellation prevented the save
    precondition(asyncCancelCallbacks == 1, "Callback must have entered exactly once")
    precondition(asyncCancelSaved == false, "Cancellation must prevent simulated save")

    print("StepFun WebKit isolation, browser capture, origin, and anonymous mode checks passed")
  }

  // Build a minimal unsigned JWT: base64url(header).base64url(payload).base64url(signature)
  private static func unsignedJWT(claims: [String: Any]) -> String {
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"], options: [])
    let payload = try! JSONSerialization.data(withJSONObject: claims, options: [])
    let sig = Data("fixture-signature".utf8)
    return "\(base64url(header)).\(base64url(payload)).\(base64url(sig))"
  }

  private static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func makeCookie(name: String, value: String, domain: String, path: String = "/") -> HTTPCookie {
    HTTPCookie(properties: [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
      HTTPCookiePropertyKey("HttpOnly"): "TRUE"
    ])!
  }

  @MainActor private static func wait(until complete: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !complete(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(complete(), "WebKit did not complete the offline operation within 15 seconds")
  }
}
