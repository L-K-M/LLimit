import Foundation

public struct CodexLoginHandle: Sendable {
  public let profile: CodexAccountProfile
  public let loginID: String
  public let authURL: URL
  fileprivate let session: CodexRPCSession
}

/// Only Codex reads, rotates, and writes managed OAuth tokens. Each operation
/// gets an isolated app-server; no agent thread or model turn is ever started.
public actor CodexAccountService: ManagedOpenAIUsageSource {
  private let store: CodexProfileStore
  private let executableOverride: URL?
  private let parentEnvironment: [String: String]
  private var sessions: [UUID: CodexRPCSession] = [:]
  private var closingTasks: [UUID: Task<Void, Error>] = [:]
  private var cleanupTasks: [UUID: Task<Void, Never>] = [:]

  public init(root: URL, executable: URL? = nil,
              environment: [String: String] = ProcessInfo.processInfo.environment) {
    store = CodexProfileStore(root: root)
    executableOverride = executable
    parentEnvironment = environment
  }

  public func beginLogin(profile: CodexAccountProfile) async throws -> CodexLoginHandle {
    var ownedSession: CodexRPCSession?
    do {
      let session = try await open(profile)
      ownedSession = session
      let result = try await session.request(method: "account/login/start", params: .object(["type": .string("chatgpt")]))
      guard let loginID = result["loginId"]?.stringValue, !loginID.isEmpty,
            let rawURL = result["authUrl"]?.stringValue, let url = URL(string: rawURL),
            url.scheme == "https", ["auth.openai.com", "chatgpt.com"].contains(url.host ?? ""),
            url.user == nil, url.password == nil, url.port == nil else { throw CodexConnectionError.signInFailed }
      return CodexLoginHandle(profile: profile, loginID: loginID, authURL: url, session: session)
    } catch {
      if let ownedSession { await recoverSession(profile, session: ownedSession) }
      throw safeError(error)
    }
  }

  public func finishLogin(_ login: CodexLoginHandle) async throws -> CodexAccountIdentity {
    let session = login.session
    guard sessions[login.profile.id] === session else { throw CodexConnectionError.cancelled }
    do {
      let deadline = Date().addingTimeInterval(600)
      while Date() < deadline {
        let notification = try await session.nextNotification(timeout: max(1, deadline.timeIntervalSinceNow))
        guard notification.method == "account/login/completed",
              notification.params["loginId"]?.stringValue == login.loginID else { continue }
        guard notification.params["success"]?.boolValue == true else { throw CodexConnectionError.signInFailed }
        let result = try await session.request(method: "account/read", params: .object(["refreshToken": .bool(false)]))
        guard result["account"]?["type"]?.stringValue == "chatgpt" else { throw CodexConnectionError.invalidProfile }
        let identity = try store.identity(login.profile)
        try await finishSession(login.profile, session: session)
        return identity
      }
      throw CodexConnectionError.signInFailed
    } catch {
      await recoverSession(login.profile, session: session)
      throw safeError(error)
    }
  }

  public func cancelLogin(_ login: CodexLoginHandle) async {
    let session = login.session
    guard sessions[login.profile.id] === session else { return }
    _ = try? await session.request(method: "account/login/cancel", params: .object(["loginId": .string(login.loginID)]))
    await recoverSession(login.profile, session: session)
  }

  public func fetchUsage(configuration: ProviderRuntimeConfiguration, now: Date) async throws -> ProviderUsage {
    guard let profile = CodexAccountProfile.profile(from: configuration.credentials),
          let expected = CodexAccountProfile.identity(from: configuration.credentials) else {
      throw ProviderClientError(kind: .auth, message: CodexConnectionError.invalidProfile.localizedDescription)
    }
    var ownedSession: CodexRPCSession?
    do {
      // Validate the stored identity before Codex can rotate anything in this profile.
      guard Self.sameIdentity(try store.identity(profile), expected) else { throw CodexConnectionError.invalidProfile }
      let session = try await open(profile)
      ownedSession = session
      let account = try await session.request(method: "account/read", params: .object(["refreshToken": .bool(true)]))
      guard account["account"]?["type"]?.stringValue == "chatgpt",
            Self.sameIdentity(try store.identity(profile), expected) else { throw CodexConnectionError.invalidProfile }
      let response = try await session.request(method: "account/rateLimits/read")
      guard Self.sameIdentity(try store.identity(profile), expected) else { throw CodexConnectionError.invalidProfile }
      let rates = try CodexRateLimits(data: JSONEncoder().encode(response))
      let usage = rates.usage(configuration: configuration, now: now)
      try await finishSession(profile, session: session)
      return usage
    } catch {
      if let ownedSession { await recoverSession(profile, session: ownedSession) }
      throw ProviderClientError(kind: .auth, message: safeError(error).localizedDescription)
    }
  }

  public func remove(_ profile: CodexAccountProfile) async -> Bool {
    guard sessions[profile.id] == nil else { return false }
    return (try? store.remove(profile)) ?? false
  }

  private static func sameIdentity(_ lhs: CodexAccountIdentity, _ rhs: CodexAccountIdentity) -> Bool {
    lhs.accountID == rhs.accountID && lhs.userID == rhs.userID
  }

  private func open(_ profile: CodexAccountProfile) async throws -> CodexRPCSession {
    guard sessions[profile.id] == nil else { throw CodexConnectionError.unfinishedOperation }
    let executable: URL
    if let executableOverride { executable = executableOverride }
    else { executable = try await Self.executable(environment: parentEnvironment) }
    // Discovery awaits a bounded version probe. Re-check ownership after that
    // suspension before acquiring the durable marker for this profile.
    guard sessions[profile.id] == nil else { throw CodexConnectionError.unfinishedOperation }
    // Acquire before prepare as another process can be active in this namespace.
    try store.acquire(profile)
    let directory: URL
    do { directory = try store.prepare(profile) }
    catch {
      try? store.release(profile)
      throw CodexConnectionError.storage
    }
    let session = CodexRPCSession(
      executable: executable,
      arguments: ["app-server", "-c", "cli_auth_credentials_store=\"file\"", "-c", "forced_login_method=\"chatgpt\""],
      environment: Self.environment(parent: parentEnvironment, directory: directory),
      workingDirectory: directory.appendingPathComponent("work", isDirectory: true))
    sessions[profile.id] = session
    do { try await session.start() }
    catch {
      // Startup can fail after a child has begun loading its credentials. Only
      // this owner may recover it; callers rejected by open own no session.
      await recoverSession(profile, session: session)
      throw error
    }
    return session
  }

  private func finishSession(_ profile: CodexAccountProfile, session: CodexRPCSession) async throws {
    guard sessions[profile.id] === session else { return }
    if let closing = closingTasks[profile.id] {
      try await closing.value
      return
    }
    // Cancellation and notification failure can arrive together. Share one
    // close/release transaction across actor reentrancy, including its errors.
    let closing = Task {
      try await session.close()
      try store.release(profile)
    }
    closingTasks[profile.id] = closing
    do {
      try await closing.value
      guard sessions[profile.id] === session else { return }
      sessions[profile.id] = nil
      closingTasks[profile.id] = nil
      cleanupTasks[profile.id] = nil
    } catch {
      closingTasks[profile.id] = nil
      throw error
    }
  }

  private func recoverSession(_ profile: CodexAccountProfile, session: CodexRPCSession) async {
    guard sessions[profile.id] === session else { return }
    if (try? await finishSession(profile, session: session)) != nil { return }
    guard cleanupTasks[profile.id] == nil else { return }
    // A timeout does not authorize replay or deletion. Keep the child and marker
    // until its outstanding request finishes and graceful exit can be observed.
    cleanupTasks[profile.id] = Task { [weak self] in
      while let self {
        if !(await session.isBusy) {
          do {
            try await self.finishSession(profile, session: session)
            return
          } catch let error as CodexRPCError where error == .busy || error == .timedOut {
            // Slow graceful exit is also uncertain until the actual child exits.
          } catch {
            await self.clearCleanupTask(profile.id, session: session)
            return
          }
        }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }

  private func clearCleanupTask(_ id: UUID, session: CodexRPCSession) {
    if sessions[id] === session { cleanupTasks[id] = nil }
  }

  private func safeError(_ error: Error) -> CodexConnectionError {
    if let error = error as? CodexConnectionError { return error }
    return .incompatibleCLI
  }

  public static func environment(parent: [String: String], directory: URL) -> [String: String] {
    // API keys, auth overrides, remote servers, inherited config and debug/log
    // settings must not redirect a managed connection to the ordinary CLI login.
    let allowed = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                   "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"]
    var result = parent.filter { allowed.contains($0.key) }
    result["CODEX_HOME"] = directory.path
    return result
  }

  public static func executable(environment: [String: String]) async throws -> URL {
    // Homebrew takes priority over old npm shims earlier on PATH.
    var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    if let home = environment["HOME"] { candidates.append(home + "/.local/bin/codex") }
    candidates += (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
    return try await CodexCLIProbe.firstSupported(candidates.map { URL(fileURLWithPath: $0) }, environment: environment)
  }
}
