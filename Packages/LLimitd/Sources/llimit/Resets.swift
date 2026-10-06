import Foundation
import QuotaCore
import LLimitdCore

/// `llimit resets` — the reset radar. Kept out of `main.swift` so the entry point
/// stays a dispatcher.
func runResets(_ args: [String]) {
  var asJSON = false
  var days = 7

  var index = 0
  while index < args.count {
    switch args[index] {
    case "--json":
      asJSON = true
    case "--days":
      guard index + 1 < args.count, let value = Int(args[index + 1]) else {
        fail("--days needs a whole number of days")
      }
      index += 1
      days = min(max(value, 1), 90)
    default:
      fail("unknown option: \(args[index])")
    }
    index += 1
  }

  let daemon = makeDaemon()
  let now = Date()
  let resets = daemon.snapshot?.upcomingResets(now: now, within: TimeInterval(days) * 86_400) ?? []

  if asJSON {
    print(StatusRenderer.resetsJSON(resets, now: now, windowDays: days))
  } else {
    print(StatusRenderer.resetsHumanReadable(resets, now: now, windowDays: days))
  }
}
