import Foundation

/// Window identity palettes. `scripts/validate-palettes.py` checks normal and
/// Machado CVD separation (base ΔE >=12, base+deep >=8), chroma and graphite
/// contrast. Labels/position distinguish variants. Blue widgets need dark
/// backing for marks; their raw contrast is measured separately.
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
        sessionHexColor: "#1FD6ED",
        dailyHexColor: "#0098F7",
        weeklyHexColor: "#FB7287",
        monthlyHexColor: "#FF6FCE",
        otherHexColors: ["#13C193", "#A2EDB9"],
        unlimitedHexColor: "#B3E5FC"
      )
    case .sunset:
      return LimitKindColors(
        sessionHexColor: "#FFD166",
        dailyHexColor: "#FB9C40",
        weeklyHexColor: "#FF6B6B",
        monthlyHexColor: "#FF6FAC",
        otherHexColors: ["#FFAB9C", "#E18AFF"],
        unlimitedHexColor: "#FFE8C2"
      )
    case .forest:
      return LimitKindColors(
        sessionHexColor: "#8EF6A9",
        dailyHexColor: "#57A94D",
        weeklyHexColor: "#EBC569",
        monthlyHexColor: "#2DBDAE",
        otherHexColors: ["#F2A586", "#D38124"],
        unlimitedHexColor: "#D8F3DC"
      )
    case .vivid:
      return LimitKindColors(
        sessionHexColor: "#00C89E",
        dailyHexColor: "#72D8FF",
        weeklyHexColor: "#FEE440",
        monthlyHexColor: "#FF6FCE",
        otherHexColors: ["#E686FF", "#FF8140"],
        unlimitedHexColor: "#C6FFF3"
      )
    }
  }

  /// The palette whose colors equal `colors`, or nil when they are custom.
  ///
  /// Rebuilt through `LimitKindColors`' normalizing initializer first: the
  /// struct's public setters do not normalize, so a value written directly (for
  /// example a lowercased hex) would otherwise compare unequal to the palette it
  /// visually matches.
  public static func matching(_ colors: LimitKindColors) -> LimitKindPalette? {
    let normalized = LimitKindColors(
      sessionHexColor: colors.sessionHexColor,
      dailyHexColor: colors.dailyHexColor,
      weeklyHexColor: colors.weeklyHexColor,
      monthlyHexColor: colors.monthlyHexColor,
      otherHexColors: colors.otherHexColors,
      unlimitedHexColor: colors.unlimitedHexColor
    )
    return allCases.first { $0.colors == normalized }
  }
}

public extension LimitKindColors {
  /// The palette these colors equal, or nil for a custom palette. Drives the
  /// Settings picker's selection.
  var palette: LimitKindPalette? {
    LimitKindPalette.matching(self)
  }
}
