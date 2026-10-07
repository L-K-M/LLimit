/// Terminal cursor control stays outside the renderers and JSON contract.
public struct WatchFrame {
  public enum Output { case terminal, stream }
  private var previousLines = 0
  public init() {}

  public mutating func render(_ text: String, output: Output) -> String {
    let prefix = output == .terminal && previousLines > 0 ? "\u{1B}[\(previousLines)A\u{1B}[J" : ""
    previousLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return prefix + text + "\n"
  }
}
