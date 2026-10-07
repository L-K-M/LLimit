import XCTest
@testable import LLimitdCore

final class WatchFrameTests: XCTestCase {
  func testTerminalRedrawErasesOldFrameWithoutClearingScrollback() {
    var frame = WatchFrame()
    XCTAssertEqual(frame.render("first\nsecond", output: .terminal), "first\nsecond\n")
    XCTAssertEqual(frame.render("new", output: .terminal), "\u{1B}[2A\u{1B}[Jnew\n")
    XCTAssertEqual(frame.render("next", output: .terminal), "\u{1B}[1A\u{1B}[Jnext\n")
  }

  func testStreamFramesNeverContainCursorControl() {
    var frame = WatchFrame()
    for _ in 0..<3 { XCTAssertEqual(frame.render("{\"text\":\"ok\"}", output: .stream), "{\"text\":\"ok\"}\n") }
  }
}
