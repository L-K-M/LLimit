import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The small JSON vocabulary used by the official Codex app-server protocol.
public enum CodexRPCValue: Codable, Equatable, Sendable {
  case object([String: CodexRPCValue])
  case array([CodexRPCValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode([String: Self].self) { self = .object(value) }
    else { self = .array(try container.decode([Self].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public subscript(key: String) -> Self? { objectValue?[key] }
  public var objectValue: [String: Self]? { if case .object(let value) = self { value } else { nil } }
  public var arrayValue: [Self]? { if case .array(let value) = self { value } else { nil } }
  public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
  public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
  public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
}

public struct CodexRPCNotification: Equatable, Sendable {
  public let method: String
  public let params: CodexRPCValue

  public init(method: String, params: CodexRPCValue) {
    self.method = method
    self.params = params
  }
}

/// Errors deliberately omit server messages, stderr, arguments and credentials.
public enum CodexRPCError: String, Error, LocalizedError, Sendable {
  case notStarted, alreadyStarted, launchFailed, invalidTimeout, invalidRequest
  case timedOut, cancelled, sessionClosed, malformedMessage, messageTooLarge
  case serverRejected, busy, notificationOverflow, writeFailed

  public var errorDescription: String? {
    switch self {
    case .notStarted: "The Codex connection has not started."
    case .alreadyStarted: "The Codex connection has already started."
    case .launchFailed: "Codex could not be started. Check that the official CLI is installed."
    case .invalidTimeout, .invalidRequest: "The Codex request is invalid."
    case .timedOut: "Codex did not respond in time. Its operation may still be running."
    case .cancelled: "Waiting for Codex was cancelled. Its operation may still be running."
    case .sessionClosed: "The Codex connection closed."
    case .malformedMessage, .messageTooLarge: "Codex returned an unsupported response."
    case .serverRejected: "Codex could not complete the request."
    case .busy: "Codex still has an operation in progress."
    case .notificationOverflow: "Codex sent more updates than this connection can handle."
    case .writeFailed: "The request could not be sent to Codex."
    }
  }
}

/// A bounded, newline-delimited JSON-RPC connection to one isolated app-server.
/// A timeout cancels only the wait: the request stays tracked until its response
/// or actual process exit, because interrupting authentication can lose a grant.
public actor CodexRPCSession {
  private enum State { case initial, starting, ready, failed, closing, closed }
  private struct RequestWaiter {
    var continuation: CheckedContinuation<CodexRPCValue, Error>?
    var timer: Task<Void, Never>?
  }
  private struct NotificationWaiter {
    let continuation: CheckedContinuation<CodexRPCNotification, Error>
    let timer: Task<Void, Never>
  }
  private struct ExitWaiter {
    let continuation: CheckedContinuation<Void, Error>
    let timer: Task<Void, Never>
  }

  private static let maximumFrameBytes = 1_048_576
  private static let maximumPendingRequests = 64
  private static let maximumNotifications = 128
  private let executable: URL
  private let arguments: [String]
  private let environment: [String: String]
  private let workingDirectory: URL
  private let writeQueue = DispatchQueue(label: "LLimit.CodexRPC.write")
  private var state = State.initial
  private var failure: CodexRPCError?
  private var process: Process?
  private var input: FileHandle?
  private let readQueue = DispatchQueue(label: "LLimit.CodexRPC.read")
  private var readerActive = false
  private var processHasExited = false
  private var outputBuffer = Data()
  private var discardingOversizedFrame = false
  private var requests: [String: RequestWaiter] = [:]
  private var notifications: [(CodexRPCNotification, Int)] = []
  private var notificationBytes = 0
  private var notificationWaiters: [UUID: NotificationWaiter] = [:]
  private var notificationOrder: [UUID] = []
  private var exitWaiters: [UUID: ExitWaiter] = [:]
  private var outstandingWriteBytes = 0
  private var outstandingWrites = 0

  public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
  }

  public var pendingRequestCount: Int { requests.count }
  public var hasExited: Bool { processHasExited }
  public var isBusy: Bool { !requests.isEmpty || outstandingWrites > 0 }

  public func start() async throws {
    guard state == .initial else { throw CodexRPCError.alreadyStarted }
    guard !Task.isCancelled else { throw CodexRPCError.cancelled }
    state = .starting
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    child.executableURL = executable
    child.arguments = arguments
    child.environment = environment
    child.currentDirectoryURL = workingDirectory
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    child.terminationHandler = { _ in Task { await self.exited() } }
    process = child
    input = stdin.fileHandleForWriting
    do {
      try child.run()
    } catch {
      child.terminationHandler = nil
      try? stdin.fileHandleForWriting.close()
      try? stdout.fileHandleForReading.close()
      process = nil
      input = nil
      processHasExited = true
      fail(.launchFailed)
      throw CodexRPCError.launchFailed
    }
    let output = stdout.fileHandleForReading
    readerActive = true
    readQueue.async {
      // FileHandle.read(upToCount:) may wait for its full count on a pipe.
      // One POSIX read returns available bytes. Backpressure on a dedicated
      // dispatch queue bounds buffering without blocking Swift cooperative tasks.
      while true {
        var bytes = Data(count: 16_384)
        let count = bytes.withUnsafeMutableBytes { buffer in
          read(output.fileDescriptor, buffer.baseAddress!, buffer.count)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { break }
        bytes.count = count
        let frame = bytes
        let consumed = DispatchSemaphore(value: 0)
        Task {
          await self.receive(frame)
          consumed.signal()
        }
        consumed.wait()
      }
      try? output.close()
      Task { await self.outputClosed() }
    }
    do {
      _ = try await sendRequest(method: "initialize", params: .object([
        "clientInfo": .object(["name": .string("llimit"), "version": .string("1")])
      ]), timeout: 45)
      guard state == .starting else { throw failure ?? CodexRPCError.sessionClosed }
      try enqueue(.object(["jsonrpc": .string("2.0"), "method": .string("initialized")]))
      state = .ready
    } catch {
      fail((error as? CodexRPCError) ?? .sessionClosed)
      throw error
    }
  }

  public func request(method: String, params: CodexRPCValue? = nil, timeout: TimeInterval = 45) async throws -> CodexRPCValue {
    guard state == .ready else { throw failure ?? (state == .initial ? CodexRPCError.notStarted : .sessionClosed) }
    return try await sendRequest(method: method, params: params, timeout: timeout)
  }

  public func nextNotification(timeout: TimeInterval = 45) async throws -> CodexRPCNotification {
    try Self.validate(timeout)
    guard !Task.isCancelled else { throw CodexRPCError.cancelled }
    if !notifications.isEmpty {
      let (notification, bytes) = notifications.removeFirst()
      notificationBytes -= bytes
      return notification
    }
    guard state == .ready || state == .starting else { throw failure ?? CodexRPCError.sessionClosed }
    guard notificationWaiters.count < Self.maximumPendingRequests else { throw CodexRPCError.busy }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CodexRPCError.cancelled); return }
        let timer = Task { await self.notificationTimeout(id, timeout: timeout) }
        notificationWaiters[id] = NotificationWaiter(continuation: continuation, timer: timer)
        notificationOrder.append(id)
      }
    } onCancel: {
      Task { await self.finishNotificationWait(id, error: .cancelled) }
    }
  }

  /// Refuses in-flight requests, drains queued writes, then closes stdin and
  /// waits for graceful exit. The shared deadline bounds both waits. A timeout
  /// always retains the process; this method never terminates a child.
  public func close(timeout: TimeInterval = 5) async throws {
    try Self.validate(timeout)
    guard requests.isEmpty else { throw CodexRPCError.busy }
    let deadline = Date().addingTimeInterval(timeout)
    if state == .initial {
      try? input?.close()
      input = nil
      state = .closed
      return
    }
    state = .closing
    for id in notificationOrder { finishNotificationWait(id, error: .sessionClosed) }
    // A response can beat its write-completion actor callback. That bookkeeping
    // delay must not turn a completed authentication request into a failure.
    while outstandingWrites > 0 {
      guard Date() < deadline else { throw CodexRPCError.timedOut }
      do { try await Task.sleep(nanoseconds: 1_000_000) }
      catch { throw CodexRPCError.cancelled }
    }
    try? input?.close()
    input = nil
    if processHasExited { state = .closed; return }
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw CodexRPCError.timedOut }
    let id = UUID()
    try await withCheckedThrowingContinuation { continuation in
      let timer = Task {
        do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
        self.exitTimeout(id)
      }
      exitWaiters[id] = ExitWaiter(continuation: continuation, timer: timer)
    }
  }

  private static func validate(_ timeout: TimeInterval) throws {
    guard timeout.isFinite, timeout >= 0, timeout <= 3_600 else { throw CodexRPCError.invalidTimeout }
  }

  private func sendRequest(method: String, params: CodexRPCValue?, timeout: TimeInterval) async throws -> CodexRPCValue {
    try Self.validate(timeout)
    guard !method.isEmpty, method.utf8.count <= 256 else { throw CodexRPCError.invalidRequest }
    guard requests.count < Self.maximumPendingRequests else { throw CodexRPCError.busy }
    guard !Task.isCancelled else { throw CodexRPCError.cancelled }
    let id = UUID().uuidString
    var frame: [String: CodexRPCValue] = ["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method)]
    if let params { frame["params"] = params }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CodexRPCError.cancelled); return }
        requests[id] = RequestWaiter(continuation: continuation)
        do {
          try enqueue(.object(frame))
          requests[id]?.timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
            self.stopWaiting(id, error: .timedOut)
          }
        } catch {
          requests.removeValue(forKey: id)
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Task { await self.stopWaiting(id, error: .cancelled) }
    }
  }

  private func enqueue(_ value: CodexRPCValue) throws {
    guard let input else { throw CodexRPCError.sessionClosed }
    guard var data = try? JSONEncoder().encode(value) else { throw CodexRPCError.invalidRequest }
    guard data.count <= Self.maximumFrameBytes else { throw CodexRPCError.messageTooLarge }
    data.append(10)
    guard outstandingWrites < Self.maximumPendingRequests,
      outstandingWriteBytes + data.count <= Self.maximumFrameBytes * 2 else { throw CodexRPCError.busy }
    outstandingWrites += 1
    outstandingWriteBytes += data.count
    // Writes are serialized off the actor so a stuck child cannot prevent request
    // deadlines from firing. Both queued bytes and queued writes have hard limits.
    let frame = data
    writeQueue.async {
      let succeeded: Bool
      do { try Self.writeFrame(frame, to: input); succeeded = true } catch { succeeded = false }
      Task { await self.writeFinished(bytes: frame.count, succeeded: succeeded) }
    }
  }

  private nonisolated static func writeFrame(_ data: Data, to handle: FileHandle) throws {
    // Darwin can deliver a pipe signal to another unblocked thread. Its
    // descriptor flag suppresses generation without changing host signal policy.
    #if canImport(Darwin)
    guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw CodexRPCError.writeFailed }
    #endif
    // Linux generates SIGPIPE on the writing thread. Block and consume only the
    // new signal, preserving the host application's existing mask and disposition.
    var pipeSignal = sigset_t()
    var previousMask = sigset_t()
    var pendingSignals = sigset_t()
    sigemptyset(&pipeSignal)
    sigaddset(&pipeSignal, SIGPIPE)
    guard pthread_sigmask(SIG_BLOCK, &pipeSignal, &previousMask) == 0 else { throw CodexRPCError.writeFailed }
    sigpending(&pendingSignals)
    let wasPending = sigismember(&pendingSignals, SIGPIPE) == 1
    defer {
      if !wasPending && sigismember(&previousMask, SIGPIPE) != 1 {
        sigpending(&pendingSignals)
        if sigismember(&pendingSignals, SIGPIPE) == 1 {
          var received: Int32 = 0
          sigwait(&pipeSignal, &received)
        }
      }
      pthread_sigmask(SIG_SETMASK, &previousMask, nil)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw CodexRPCError.writeFailed }
        offset += count
      }
    }
  }

  private func writeFinished(bytes: Int, succeeded: Bool) {
    outstandingWrites -= 1
    outstandingWriteBytes -= bytes
    if !succeeded { fail(.writeFailed) }
  }

  private func receive(_ data: Data) {
    for byte in data {
      if discardingOversizedFrame {
        if byte == 10 { discardingOversizedFrame = false }
        continue
      }
      if byte == 10 {
        let frame = outputBuffer
        outputBuffer.removeAll(keepingCapacity: true)
        if !frame.isEmpty { receiveFrame(frame) }
      } else if outputBuffer.count < Self.maximumFrameBytes {
        outputBuffer.append(byte)
      } else {
        outputBuffer.removeAll(keepingCapacity: true)
        discardingOversizedFrame = true
        fail(.messageTooLarge)
      }
    }
  }

  private func receiveFrame(_ data: Data) {
    guard let value = try? JSONDecoder().decode(CodexRPCValue.self, from: data),
      let object = value.objectValue,
      object["jsonrpc"] == nil || object["jsonrpc"] == .string("2.0") else { fail(.malformedMessage); return }
    if let method = object["method"]?.stringValue {
      guard method.utf8.count <= 256 else { fail(.malformedMessage); return }
      if let id = object["id"] {
        guard id.stringValue != nil || id.numberValue != nil else { fail(.malformedMessage); return }
        // LLimit does not run turns or handle credential-token delegation requests.
        // Reject unexpected requests without echoing their potentially secret params.
        do {
          try enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
            "code": .number(-32601), "message": .string("Method not supported")
          ])]))
        } catch { fail(.writeFailed) }
        return
      }
      guard state == .ready || state == .starting else { return }
      let notification = CodexRPCNotification(method: method, params: object["params"] ?? .null)
      if let id = notificationOrder.first, let waiter = notificationWaiters.removeValue(forKey: id) {
        notificationOrder.removeFirst()
        waiter.timer.cancel()
        waiter.continuation.resume(returning: notification)
      } else {
        guard notifications.count < Self.maximumNotifications,
          notificationBytes + data.count <= Self.maximumFrameBytes else { fail(.notificationOverflow); return }
        notifications.append((notification, data.count))
        notificationBytes += data.count
      }
      return
    }
    guard let id = object["id"]?.stringValue,
      (object["result"] != nil) != (object["error"] != nil) else { fail(.malformedMessage); return }
    guard let waiter = requests.removeValue(forKey: id) else { return }
    waiter.timer?.cancel()
    if let result = object["result"] { waiter.continuation?.resume(returning: result) }
    else { waiter.continuation?.resume(throwing: CodexRPCError.serverRejected) }
  }

  private func stopWaiting(_ id: String, error: CodexRPCError) {
    guard var waiter = requests[id], let continuation = waiter.continuation else { return }
    waiter.timer?.cancel()
    waiter.timer = nil
    waiter.continuation = nil
    requests[id] = waiter
    continuation.resume(throwing: error)
  }

  private func notificationTimeout(_ id: UUID, timeout: TimeInterval) async {
    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
    finishNotificationWait(id, error: .timedOut)
  }

  private func finishNotificationWait(_ id: UUID, error: CodexRPCError) {
    guard let waiter = notificationWaiters.removeValue(forKey: id) else { return }
    notificationOrder.removeAll { $0 == id }
    waiter.timer.cancel()
    waiter.continuation.resume(throwing: error)
  }

  private func fail(_ error: CodexRPCError) {
    if failure == nil { failure = error }
    if state != .closed { state = .failed }
    for id in requests.keys { stopWaiting(id, error: error) }
    for id in notificationOrder { finishNotificationWait(id, error: error) }
    notifications.removeAll()
    notificationBytes = 0
  }

  private func outputClosed() {
    readerActive = false
    if !outputBuffer.isEmpty { fail(.malformedMessage) }
    outputBuffer.removeAll()
    fail(.sessionClosed)
    if processHasExited { requests.removeAll() }
  }

  private func exited() {
    processHasExited = true
    process?.terminationHandler = nil
    // A child may exit immediately after its last response. The reader must drain
    // stdout before failing requests or discarding their response continuations.
    if !readerActive {
      fail(.sessionClosed)
      requests.removeAll()
    }
    for waiter in exitWaiters.values {
      waiter.timer.cancel()
      waiter.continuation.resume()
    }
    exitWaiters.removeAll()
    if state == .closing { state = .closed }
    process = nil
  }

  private func exitTimeout(_ id: UUID) {
    guard let waiter = exitWaiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: CodexRPCError.timedOut)
  }
}
