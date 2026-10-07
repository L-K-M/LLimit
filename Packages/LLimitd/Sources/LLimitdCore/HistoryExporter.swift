import Foundation
import QuotaCore

/// Serializes the recorded quota history for scripts and spreadsheets. Reads
/// only the history archive, which is credential-free by contract.
public enum HistoryExporter {
  private static let formulaPrefixCharacters = CharacterSet(charactersIn: "=+-@\t\r\n")

  /// One CSV row per metric sample:
  /// `generatedAt,account_id,provider,account,metric,label,remaining_percent,remaining_amount,reset_at`.
  public static func csv(history: [QuotaSnapshot]) -> String {
    var lines = ["generatedAt,account_id,provider,account,metric,label,remaining_percent,remaining_amount,reset_at"]
    let iso = ISO8601DateFormatter()
    for snapshot in history.sorted(by: { $0.generatedAt < $1.generatedAt }) {
      let stamp = iso.string(from: snapshot.generatedAt)
      for usage in snapshot.providers {
        for metric in usage.metrics {
          let fields: [String] = [
            stamp,
            usage.accountID,
            usage.provider.rawValue,
            usage.title,
            metric.id,
            metric.label,
            metric.remainingPercent.map(String.init) ?? "",
            metric.remainingAmount.map { String($0) } ?? "",
            metric.resetAt.map(iso.string) ?? "",
          ]
          lines.append(fields.map(escape).joined(separator: ","))
        }
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// The archive re-encoded as pretty JSON — same shape as the on-disk file.
  public static func json(history: [QuotaSnapshot]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(history.sorted { $0.generatedAt < $1.generatedAt })
    return String(decoding: data, as: UTF8.self)
  }

  private static func escape(_ field: String) -> String {
    // Spreadsheet-safety: a leading =, +, - or @ is interpreted as a formula by
    // Excel/Numbers even inside quotes — neutralize with a leading apostrophe.
    // Leading tab/CR/newline get the same treatment: some importers trim
    // them, re-exposing a formula prefix. CharacterSet works at scalar level —
    // a Character literal "\r\n" would be one grapheme and never match.
    let guarded = field.unicodeScalars.first.map(Self.formulaPrefixCharacters.contains) == true
      ? "'" + field : field
    guard guarded.contains(",") || guarded.contains("\"") || guarded.contains("\n") || guarded.contains("\r") else {
      return guarded
    }
    return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
