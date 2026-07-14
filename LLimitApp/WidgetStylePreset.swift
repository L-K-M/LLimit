import QuotaCore

struct WidgetStylePreset: Identifiable, Hashable {
  let id: String
  let displayName: String
  let style: WidgetStyleSettings

  static let customID = "__custom__"

  static let all: [WidgetStylePreset] = [
    WidgetStylePreset(
      id: "default",
      displayName: "Default",
      style: style(nil, .default)
    ),
    WidgetStylePreset(
      id: "classic",
      displayName: "Classic",
      style: style("#475270", .default)
    ),
    WidgetStylePreset(
      id: "graphite",
      displayName: "Graphite",
      style: style(
        "#333A4A",
        rings(outerHigh: "#E5ECFA", outerMedium: "#A7B3CB", outerLow: "#6E7A96", outerUnlimited: "#C7D4F0")
      )
    ),
    WidgetStylePreset(
      id: "ocean",
      displayName: "Ocean",
      style: style(
        "#1B6CB9",
        rings(outerHigh: "#66E1FF", outerMedium: "#30B4FF", outerLow: "#147FE6", outerUnlimited: "#A3F0FF")
      )
    ),
    WidgetStylePreset(
      id: "forest",
      displayName: "Forest",
      style: style(
        "#1F7A4D",
        rings(outerHigh: "#9BF5B4", outerMedium: "#58D886", outerLow: "#2FA05B", outerUnlimited: "#D8FFE4")
      )
    ),
    WidgetStylePreset(
      id: "sunset",
      displayName: "Sunset",
      style: style(
        "#C45A3A",
        rings(outerHigh: "#FFD06A", outerMedium: "#FF9E4A", outerLow: "#FF5E4A", outerUnlimited: "#FFF0A6")
      )
    ),
    WidgetStylePreset(
      id: "midnight",
      displayName: "Midnight",
      style: style(
        "#1D2340",
        rings(outerHigh: "#A3B7FF", outerMedium: "#6D8FFF", outerLow: "#4E67C9", outerUnlimited: "#D5E1FF")
      )
    ),
    WidgetStylePreset(
      id: "royal-velvet",
      displayName: "Royal Velvet",
      style: style(
        "#4D2D8A",
        rings(outerHigh: "#D8B7FF", outerMedium: "#A67CFF", outerLow: "#7A4DDB", outerUnlimited: "#EFD9FF")
      )
    ),
    WidgetStylePreset(
      id: "purple-nurple",
      displayName: "Purple Nurple",
      style: style(
        "#6A38B5",
        rings(
          outerHigh: "#E8D4FF",
          outerMedium: "#C396FF",
          outerLow: "#8E59E8",
          outerUnlimited: "#F2E4FF",
          innerHigh: "#F4E9FF",
          innerMedium: "#D9B7FF",
          innerLow: "#A674F4",
          innerUnlimited: "#FAF2FF"
        )
      )
    ),
    WidgetStylePreset(
      id: "copper-ember",
      displayName: "Copper Ember",
      style: style(
        "#8B4A2F",
        rings(outerHigh: "#FFC18C", outerMedium: "#E58A5B", outerLow: "#BD5A3A", outerUnlimited: "#FFDDB7")
      )
    ),
    WidgetStylePreset(
      id: "glacier",
      displayName: "Glacier",
      style: style(
        "#3A87A8",
        rings(outerHigh: "#D9F8FF", outerMedium: "#9DDEFF", outerLow: "#5BB4E2", outerUnlimited: "#FFFFFF")
      )
    ),
    WidgetStylePreset(
      id: "mint-pop",
      displayName: "Mint Pop",
      style: style(
        "#1F8A74",
        rings(outerHigh: "#B6FFE8", outerMedium: "#63E6C5", outerLow: "#22B18D", outerUnlimited: "#E6FFF7")
      )
    ),
    WidgetStylePreset(
      id: "rose-quartz",
      displayName: "Rose Quartz",
      style: style(
        "#A6527A",
        rings(outerHigh: "#FFD5E8", outerMedium: "#F89DC4", outerLow: "#D96A99", outerUnlimited: "#FFEAF4")
      )
    ),
    WidgetStylePreset(
      id: "neon-pulse",
      displayName: "Neon Pulse",
      style: style(
        "#22203E",
        rings(
          outerHigh: "#36FCD0",
          outerMedium: "#00D8FF",
          outerLow: "#FF48A6",
          outerUnlimited: "#A4FF41",
          innerHigh: "#7DFFE7",
          innerMedium: "#8CF1FF",
          innerLow: "#FF8BC7",
          innerUnlimited: "#CCFF8A"
        )
      )
    ),
    WidgetStylePreset(
      id: "synthwave-80s",
      displayName: "Synthwave 80s",
      style: style(
        "#402060",
        rings(
          outerHigh: "#FF8A00",
          outerMedium: "#FF2E88",
          outerLow: "#8B2FFF",
          outerUnlimited: "#18F8FF",
          innerHigh: "#FFBE5C",
          innerMedium: "#FF74B5",
          innerLow: "#B67BFF",
          innerUnlimited: "#83F9FF"
        )
      )
    ),
    WidgetStylePreset(
      id: "cyberpunk",
      displayName: "Cyberpunk",
      style: style(
        "#161923",
        rings(
          outerHigh: "#F5FF2B",
          outerMedium: "#00F7FF",
          outerLow: "#FF2674",
          outerUnlimited: "#A855FF",
          innerHigh: "#FBFF83",
          innerMedium: "#83FCFF",
          innerLow: "#FF80AF",
          innerUnlimited: "#CF9CFF"
        )
      )
    ),
    WidgetStylePreset(
      id: "crazy-banana",
      displayName: "Crazy Banana",
      style: style(
        "#D9B21B",
        rings(
          outerHigh: "#FFF9B1",
          outerMedium: "#FFE45E",
          outerLow: "#FF9D00",
          outerUnlimited: "#A5FF3C",
          innerHigh: "#FFFFD6",
          innerMedium: "#FFEF8A",
          innerLow: "#FFBD52",
          innerUnlimited: "#D3FF87"
        )
      )
    ),
    WidgetStylePreset(
      id: "lime-laser",
      displayName: "Lime Laser",
      style: style(
        "#3F6B1A",
        rings(
          outerHigh: "#D8FF43",
          outerMedium: "#A6F222",
          outerLow: "#69C30F",
          outerUnlimited: "#F0FF8A",
          innerHigh: "#EDFF92",
          innerMedium: "#C5FF5A",
          innerLow: "#89DB2D",
          innerUnlimited: "#F8FFBE"
        )
      )
    ),
    WidgetStylePreset(
      id: "lava-burst",
      displayName: "Lava Burst",
      style: style(
        "#8A2E21",
        rings(
          outerHigh: "#FFD16B",
          outerMedium: "#FF7A2F",
          outerLow: "#E12F1F",
          outerUnlimited: "#FFF2A8",
          innerHigh: "#FFE3A0",
          innerMedium: "#FFA364",
          innerLow: "#FF5B43",
          innerUnlimited: "#FFF8CD"
        )
      )
    ),
    WidgetStylePreset(
      id: "aurora",
      displayName: "Aurora",
      style: style(
        "#255A6A",
        rings(
          outerHigh: "#70F2FF",
          outerMedium: "#65D1A5",
          outerLow: "#6E95FF",
          outerUnlimited: "#CCFFEE",
          innerHigh: "#A8F8FF",
          innerMedium: "#A6F2D4",
          innerLow: "#A7BEFF",
          innerUnlimited: "#ECFFF8"
        )
      )
    ),
    WidgetStylePreset(
      id: "desert-bloom",
      displayName: "Desert Bloom",
      style: style(
        "#A5713D",
        rings(
          outerHigh: "#FFE4A8",
          outerMedium: "#F4B96B",
          outerLow: "#D97A41",
          outerUnlimited: "#FFF2CE",
          innerHigh: "#FFEFCB",
          innerMedium: "#FFD392",
          innerLow: "#EB9968",
          innerUnlimited: "#FFF8E0"
        )
      )
    ),
    WidgetStylePreset(
      id: "candy-pop",
      displayName: "Candy Pop",
      style: style(
        "#B34FA2",
        rings(
          outerHigh: "#8CFFF3",
          outerMedium: "#7DB0FF",
          outerLow: "#FF6FB5",
          outerUnlimited: "#FFE95A",
          innerHigh: "#B9FFF7",
          innerMedium: "#ADC9FF",
          innerLow: "#FFA3D0",
          innerUnlimited: "#FFF4A8"
        )
      )
    ),
    WidgetStylePreset(
      id: "monochrome-ice",
      displayName: "Monochrome Ice",
      style: style(
        "#4F5A72",
        rings(
          outerHigh: "#FFFFFF",
          outerMedium: "#DCE4F5",
          outerLow: "#A6B4CF",
          outerUnlimited: "#F4F8FF",
          innerHigh: "#FFFFFF",
          innerMedium: "#EAF0FF",
          innerLow: "#C1CCE4",
          innerUnlimited: "#FBFDFF"
        )
      )
    ),
    WidgetStylePreset(
      id: "crystal-clear",
      displayName: "Crystal Clear",
      style: style(nil, .default, transparent: true)
    )
  ]

  static func preset(withID id: String) -> WidgetStylePreset? {
    all.first(where: { $0.id == id })
  }

  static func id(for style: WidgetStyleSettings) -> String {
    // Limit identity colors are not part of any preset — neutralize them so a
    // customized limit palette doesn't knock the picker back to "Custom".
    var normalized = style
    normalized.limitKindColors = .default
    return all.first(where: { $0.style == normalized })?.id ?? customID
  }
}

private extension WidgetStylePreset {
  static func style(
    _ backgroundHexColor: String?,
    _ ringColors: WidgetRingColors,
    transparent: Bool = false
  ) -> WidgetStyleSettings {
    WidgetStyleSettings(
      backgroundHexColor: backgroundHexColor,
      ringColors: ringColors,
      useTransparentBackground: transparent
    )
  }

  static func rings(
    outerHigh: String,
    outerMedium: String,
    outerLow: String,
    outerUnlimited: String,
    innerHigh: String? = nil,
    innerMedium: String? = nil,
    innerLow: String? = nil,
    innerUnlimited: String? = nil
  ) -> WidgetRingColors {
    WidgetRingColors(
      outerHighHexColor: outerHigh,
      outerMediumHexColor: outerMedium,
      outerLowHexColor: outerLow,
      outerUnlimitedHexColor: outerUnlimited,
      innerHighHexColor: innerHigh ?? outerHigh,
      innerMediumHexColor: innerMedium ?? outerMedium,
      innerLowHexColor: innerLow ?? outerLow,
      innerUnlimitedHexColor: innerUnlimited ?? outerUnlimited
    )
  }
}
