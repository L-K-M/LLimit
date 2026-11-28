import Foundation

/// Provider tiles carry only a Settings destination and, when assigned, the account ID.
public enum ProviderTileDestination: Equatable, Sendable {
  case account(String)
  case widgets

  private static let scheme = "llimit"

  public var url: URL? {
    var components = URLComponents()
    components.scheme = Self.scheme
    switch self {
    case .account(let id):
      guard Self.isValidAccountID(id) else { return nil }
      components.host = "account"
      components.queryItems = [URLQueryItem(name: "id", value: id)]
    case .widgets:
      components.host = "widgets"
    }
    return components.url
  }

  public init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == Self.scheme, components.path.isEmpty,
          components.user == nil, components.password == nil, components.port == nil,
          components.fragment == nil else { return nil }

    switch components.host?.lowercased() {
    case "account":
      guard let items = components.queryItems, items.count == 1, items[0].name == "id",
            let id = items[0].value, Self.isValidAccountID(id) else { return nil }
      self = .account(id)
    case "widgets" where components.query == nil:
      self = .widgets
    default:
      return nil
    }
  }

  private static func isValidAccountID(_ id: String) -> Bool {
    !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && id.rangeOfCharacter(from: .controlCharacters) == nil
  }
}
