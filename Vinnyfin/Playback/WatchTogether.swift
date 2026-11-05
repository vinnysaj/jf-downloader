import CoreTransferable
import Foundation
import GroupActivities

/// Watching a title together over SharePlay: the server it plays from and the title, which
/// changes as the group moves to another episode. Everyone plays it from their own sign-in to
/// that server, so only people with access to it can join.
nonisolated struct WatchTogether: GroupActivity, Hashable {
    static let activityIdentifier = "net.vinnysaj.vinnyfin.watch-together"

    /// The server's own id, the same at every address it's reached by.
    var serverId: String
    var serverName: String
    var itemId: String
    var title: String
    var subtitle: String?

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .watchTogether
        metadata.title = title
        metadata.subtitle = subtitle
        // An iPhone on a call can hand the activity to an Apple TV, which plays it in vinnyfin there.
        metadata.supportsContinuationOnTV = true
        return metadata
    }

    /// Whether someone signed in to `account`, or to nothing, can play what the group plays.
    enum Access: Equatable, Sendable {
        case allowed
        case notSignedIn
        case otherServer(String)
    }

    func access(for account: AccountStore.Account?) -> Access {
        guard let account else { return .notSignedIn }
        return account.serverId == serverId ? .allowed : .otherServer(account.serverName ?? account.serverURL.host() ?? "another server")
    }

    /// What this device says when it can't join.
    func refusal(_ access: Access) -> String? {
        switch access {
        case .allowed:
            nil
        case .notSignedIn:
            "\(title) is playing from \(serverName). Sign in to \(serverName) in vinnyfin to watch together."
        case .otherServer(let other):
            "\(title) is playing from \(serverName), and vinnyfin here is signed in to \(other). Sign in to \(serverName) to watch together."
        }
    }
}

#if !os(tvOS)
/// Offered in the share sheet, which starts SharePlay with people who aren't on a call yet.
extension WatchTogether: Transferable {}
#endif

/// Told to the group by someone who can't watch with it.
nonisolated struct CantWatch: Codable, Equatable, Sendable {
    enum Reason: Codable, Equatable, Sendable {
        case notSignedIn
        case otherServer
        /// The title didn't play: the message the player gave.
        case failed(String)
    }

    var reason: Reason

    init(_ reason: Reason) {
        self.reason = reason
    }

    init?(_ access: WatchTogether.Access) {
        switch access {
        case .allowed: return nil
        case .notSignedIn: reason = .notSignedIn
        case .otherServer: reason = .otherServer
        }
    }

    /// How the others are told, in a list of everyone who can't watch.
    func describe(serverName: String) -> String {
        switch reason {
        case .notSignedIn: "Someone isn't signed in to \(serverName)."
        case .otherServer: "Someone is signed in to a different server than \(serverName)."
        case .failed(let message): "It didn't play for someone: \(message)"
        }
    }
}
