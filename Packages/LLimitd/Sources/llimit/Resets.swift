import Foundation
import QuotaCore
import LLimitdCore

/// `llimit resets` — the reset radar. Kept out of `main.swift` so the entry point
/// stays a dispatcher.
func runResets(_ args: [String]) {
  let options = parseResetsOptionsOrFail(args)

  let daemon = makeDaemon()
  let now = Date()

  if options.asJSON {
    print(StatusRenderer.resetsJSON(snapshot: daemon.snapshot, now: now, windowDays: options.days))
  } else {
    print(StatusRenderer.resetsHumanReadable(snapshot: daemon.snapshot, now: now, windowDays: options.days))
  }
}

private func parseResetsOptionsOrFail(_ args: [String]) -> ResetsOptions {
  do {
    return try parseResetsOptions(args)
  } catch let error as ResetsOptionError {
    fail(error.message)
  } catch {
    fail("invalid arguments")
  }
}
