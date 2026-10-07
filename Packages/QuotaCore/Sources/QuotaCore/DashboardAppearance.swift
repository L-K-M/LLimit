import Foundation

/// Neutral dashboard surfaces; quota hues remain independent of appearance.
public enum DashboardAppearance: CaseIterable, Sendable {
  case light
  case dark

  public var backgroundTopHex: String { self == .light ? "#F5F6FA" : "#1D1F27" }
  public var backgroundBottomHex: String { self == .light ? "#E7EAF2" : "#101116" }
  public var primaryTextHex: String { self == .light ? "#171923" : "#F4F5F8" }
  public var secondaryTextHex: String { self == .light ? "#494D5A" : "#B5B8C5" }
  public var tertiaryTextHex: String { self == .light ? "#565B6B" : "#A0A5B7" }
  public var cardHex: String { self == .light ? "#FFFFFF" : "#272A34" }
  public var cardHoverHex: String { self == .light ? "#F7F8FC" : "#2C303B" }
  public var warningHex: String { self == .light ? "#945200" : "#FFBF69" }
  public var dangerHex: String { self == .light ? "#B52323" : "#FF9890" }
  public var successHex: String { self == .light ? "#216B3B" : "#79D899" }
}
