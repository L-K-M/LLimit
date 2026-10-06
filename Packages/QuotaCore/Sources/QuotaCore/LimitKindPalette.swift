import Foundation

/// Curated palettes for the limit identity colors (`LimitKindColors`).
///
/// Color in LLimit encodes *which* limit a mark belongs to, so a palette is a
/// themed set of those identity hues rather than a single accent. Choosing one
/// retints every surface at once — dashboard rings, bars and sparklines, the
/// menu-bar bars, the widgets and the trend chart — instead of editing seven
/// swatches by hand.
public enum LimitKindPalette: String, CaseIterable, Codable, Sendable {
  case standard
  case ocean
  case sunset
  case forest
  case vivid

  public var displayName: String {
    switch self {
    case .standard:
      return "Standard"
    case .ocean:
      return "Ocean"
    case .sunset:
      return "Sunset"
    case .forest:
      return "Forest"
    case .vivid:
      return "Vivid"
    }
  }

  /// The palette's colors. Values are validated by `LimitKindColors`, which
  /// normalizes each hex and falls back to the standard color if one is malformed.
  public var colors: LimitKindColors {
    switch self {
    case .standard:
      return .default
    case .ocean:
      return LimitKindColors(
        sessionHexColor: "#3ED8F0",
        dailyHexColor: "#2FB6C9",
        weeklyHexColor: "#4E8BFF",
        monthlyHexColor: "#8B7BFF",
        otherHexColors: ["#5FD0A8", "#2E6FD8"],
        unlimitedHexColor: "#C2E5FF"
      )
    case .sunset:
      return LimitKindColors(
        sessionHexColor: "#FFD166",
        dailyHexColor: "#FF9F45",
        weeklyHexColor: "#FF6B6B",
        monthlyHexColor: "#E85D9B",
        otherHexColors: ["#FFB4A2", "#C77DFF"],
        unlimitedHexColor: "#FFE8C2"
      )
    case .forest:
      return LimitKindColors(
        sessionHexColor: "#8CE99A",
        dailyHexColor: "#40C057",
        weeklyHexColor: "#E9C46A",
        monthlyHexColor: "#2A9D8F",
        otherHexColors: ["#A3B18A", "#BC6C25"],
        unlimitedHexColor: "#D8F3DC"
      )
    case .vivid:
      return LimitKindColors(
        sessionHexColor: "#00F5D4",
        dailyHexColor: "#00BBF9",
        weeklyHexColor: "#FEE440",
        monthlyHexColor: "#F15BB5",
        otherHexColors: ["#9B5DE5", "#FF7A00"],
        unlimitedHexColor: "#C6FFF3"
      )
    }
  }

  /// The palette whose colors equal `colors`, or nil when they are custom.
  public static func matching(_ colors: LimitKindColors) -> LimitKindPalette? {
    allCases.first { $0.colors == colors }
  }
}

public extension LimitKindColors {
  /// The palette these colors equal, or nil for a custom palette. Drives the
  /// Settings picker's selection.
  var palette: LimitKindPalette? {
    LimitKindPalette.matching(self)
  }
}
