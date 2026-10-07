import Foundation
import QuotaCore

public enum HistoryExporter {
  private static let formulaPrefixes = CharacterSet(charactersIn: "=+-@\t\r\n")
  private static let header = "generatedAt,account_id,provider,account,metric,label,remaining_percent,remaining_amount,reset_at"

  public static func csv(history: [QuotaSnapshot]) -> String {
    var lines = [header]
    for snapshot in history.sorted(by: { $0.generatedAt < $1.generatedAt }) {
      for usage in snapshot.providers {
        for metric in usage.metrics {
          let fields = [
            StatusRenderer.iso8601String(snapshot.generatedAt), usage.accountID, usage.provider.rawValue, usage.title,
            metric.id, metric.label, metric.remainingPercent.map(String.init) ?? "",
            metric.remainingAmount.map { String($0) } ?? "", metric.resetAt.map(StatusRenderer.iso8601String) ?? ""
          ]
          lines.append(fields.map(escape).joined(separator: ","))
        }
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func json(history: [QuotaSnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(history.sorted { $0.generatedAt < $1.generatedAt }), as: UTF8.self)
  }

  private static func escape(_ field: String) -> String {
    // Spreadsheets may trim whitespace before detecting a formula. Quote alone
    // does not neutralize one; inspect the first non-whitespace scalar too.
    let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
    let dangerous = field.unicodeScalars.first.map(formulaPrefixes.contains) == true
      || trimmed.unicodeScalars.first.map(formulaPrefixes.contains) == true
    let guarded = dangerous ? "'" + field : field
    guard guarded.contains(",") || guarded.contains("\"") || guarded.contains(where: \.isNewline) else { return guarded }
    return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

public struct ExportOptions: Equatable, Sendable {
  public enum Format: String, Sendable { case csv, json }
  public var format: Format = .json
  public var days: Int?
  public init() {}

  public static func parse(_ args: [String]) throws -> ExportOptions {
    var options = ExportOptions()
    var index = 0
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--format":
        let raw = try CommandLineValues.value(after: arg, in: args, at: &index)
        guard let format = Format(rawValue: raw.lowercased()) else { throw CommandLineError("--format needs csv or json") }
        options.format = format
      case "--days":
        let raw = try CommandLineValues.value(after: arg, in: args, at: &index)
        guard let days = Int(raw), days > 0 else { throw CommandLineError("--days needs a positive integer") }
        options.days = days
      default: throw CommandLineError("unknown export option: \(arg)")
      }
      index += 1
    }
    return options
  }
}
