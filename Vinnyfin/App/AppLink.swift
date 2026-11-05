import Foundation

/// A link into the app, as Apple TV's Top Shelf and Handoff hand it over:
/// `vinnyfin://item/<id>?type=…&name=…` opens a title's page, and `vinnyfin://play/<id>?type=…&name=…`
/// plays it from where it was left, or with `&position=<seconds>` from there at the earliest. The
/// type and name let the page or the player open before the server has answered.
nonisolated struct AppLink: Equatable, Sendable {
    enum Action: String, Sendable {
        case open = "item"
        case play
    }

    static let scheme = "vinnyfin"

    var action: Action
    var itemId: String
    var type: String
    var name: String
    /// Where another device had got to, in whole seconds, for a playback continued from it.
    var position: Double?

    init(_ action: Action, _ item: JellyfinItem, position: Double? = nil) {
        self.action = action
        itemId = item.id
        type = item.type
        name = item.name
        self.position = position.flatMap(Self.wholeSeconds)
    }

    /// Nil when the URL isn't a link into the app.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.host.flatMap({ Action(rawValue: $0.lowercased()) })
        else { return nil }
        let itemId = String(components.path.dropFirst())
        let query = components.queryItems ?? []
        guard components.path.hasPrefix("/"), !itemId.isEmpty, !itemId.contains("/"),
              let type = query.first(where: { $0.name == "type" })?.value, !type.isEmpty,
              let name = query.first(where: { $0.name == "name" })?.value
        else { return nil }
        self.action = action
        self.itemId = itemId
        self.type = type
        self.name = name
        position = query.first { $0.name == "position" }?.value.flatMap(Double.init).flatMap(Self.wholeSeconds)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.path = "/" + itemId
        components.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "name", value: name)]
        if let position { components.queryItems?.append(URLQueryItem(name: "position", value: String(format: "%.0f", position))) }
        // A scheme, a host and a path that starts with a slash always make a URL.
        return components.url!
    }

    /// The title as far as the link describes it; its page and the player load the rest.
    var item: JellyfinItem {
        JellyfinItem(id: itemId, name: name, type: type)
    }

    /// A position as the link carries it; nil for one that isn't a time into the title.
    private static func wholeSeconds(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds >= 0 ? seconds.rounded(.down) : nil
    }
}
