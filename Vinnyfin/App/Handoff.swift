import SwiftUI

/// What a device hands to the person's other devices through Handoff: the title whose page is
/// open, or the one playing and how far it got, and the server and person it's from. Continuing
/// on the other device opens the title as a link into the app does. The activity names the
/// server's address, so a device signed in elsewhere can offer to sign in to it. Apple TV takes
/// no part: tvOS neither offers activities to other devices nor continues them.
nonisolated struct Handoff: Equatable, Sendable {
    /// The activity vinnyfin hands off, as listed under `NSUserActivityTypes` in Info.plist: a
    /// title's page or its playback, which the link tells apart.
    static let activityType = "net.vinnysaj.vinnyfin.title"

    var link: AppLink
    var signIn: ServerSignIn

    private enum Key {
        static let link = "link"
        static let serverId = "serverId"
        static let serverName = "serverName"
        static let serverAddress = "serverAddress"
        static let userId = "userId"
        static let userName = "userName"
    }

    init(link: AppLink, signIn: ServerSignIn) {
        self.link = link
        self.signIn = signIn
    }

    /// Nil for another app's activity, or one that's missing something.
    init?(_ activity: NSUserActivity) {
        guard activity.activityType == Self.activityType else { return nil }
        self.init(userInfo: activity.userInfo ?? [:])
    }

    init?(userInfo: [AnyHashable: Any]) {
        func string(_ key: String) -> String? {
            (userInfo[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let link = string(Key.link).flatMap(URL.init(string:)).flatMap(AppLink.init),
              let serverId = string(Key.serverId),
              let address = string(Key.serverAddress).flatMap(URL.init(string:)),
              let userId = string(Key.userId),
              let userName = string(Key.userName)
        else { return nil }
        self.link = link
        signIn = ServerSignIn(serverId: serverId, serverName: string(Key.serverName), address: address,
                              userId: userId, userName: userName)
    }

    var userInfo: [String: String] {
        var info = [
            Key.link: link.url.absoluteString,
            Key.serverId: signIn.serverId,
            Key.serverAddress: signIn.address.absoluteString,
            Key.userId: signIn.userId,
            Key.userName: signIn.userName,
        ]
        info[Key.serverName] = signIn.serverName
        return info
    }

    /// Jellyfin's own page for the title, which a device without vinnyfin opens in its browser.
    var webpageURL: URL? {
        guard var components = URLComponents(url: signIn.address, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased())
        else { return nil }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "web/"
        components.query = nil
        var route = URLComponents()
        route.path = "/details"
        route.queryItems = [URLQueryItem(name: "id", value: link.itemId), URLQueryItem(name: "serverId", value: signIn.serverId)]
        components.fragment = route.string
        return components.url
    }

    /// Fills in the activity for the other devices to offer.
    func describe(_ activity: NSUserActivity) {
        activity.title = link.name
        activity.userInfo = userInfo
        activity.requiredUserInfoKeys = Set(userInfo.keys)
        activity.webpageURL = webpageURL
        activity.isEligibleForHandoff = true
    }

    // MARK: Another sign-in

    /// How this device's sign-in differs from the one the title came from.
    enum Mismatch: Equatable, Sendable {
        case notSignedIn
        case otherServer(AccountStore.Account)
        case otherUser(AccountStore.Account)
    }

    /// Nil when this device is signed in as the person the title came from.
    func mismatch(with account: AccountStore.Account?) -> Mismatch? {
        guard let account else { return .notSignedIn }
        if account.serverId != signIn.serverId { return .otherServer(account) }
        if account.userId != signIn.userId { return .otherUser(account) }
        return nil
    }

    static func title(for mismatch: Mismatch) -> String {
        switch mismatch {
        case .notSignedIn: "Sign In to Continue"
        case .otherServer: "Signed In to Another Server"
        case .otherUser: "Signed In as Someone Else"
        }
    }

    /// Says where the title is from and where this device is signed in, in so many words.
    func explanation(for mismatch: Mismatch, on device: String) -> String {
        let from = "“\(link.name)” is from \(signIn.serverTitle), signed in as \(signIn.userName)."
        switch mismatch {
        case .notSignedIn:
            return "\(from) This \(device) isn't signed in."
        case .otherServer(let account):
            let here = account.serverName ?? account.serverURL.host() ?? "another server"
            return "\(from) This \(device) is signed in to \(here) as \(account.userName), and switching signs it out there."
        case .otherUser(let account):
            return "\(from) This \(device) is signed in to it as \(account.userName), and switching signs \(account.userName) out."
        }
    }

    /// The button that signs in to where the title is from.
    func signInTitle(for mismatch: Mismatch) -> String {
        switch mismatch {
        case .notSignedIn: "Sign In to \(signIn.serverTitle)"
        case .otherServer: "Switch to \(signIn.serverTitle)"
        case .otherUser: "Switch to \(signIn.userName)"
        }
    }
}

extension View {
    /// Offers the title's page to the person's other devices while it's on screen and the player
    /// doesn't cover it. Apple TV has no Handoff.
    func handoffPage(_ item: JellyfinItem) -> some View {
        #if os(tvOS)
        self
        #else
        modifier(PageHandoff(item: item))
        #endif
    }

    #if !os(tvOS)
    /// Offers the playback to the person's other devices, at the position it has reached.
    func handoffPlayback(_ model: PlayerModel) -> some View {
        modifier(PlaybackHandoff(model: model))
    }
    #endif
}

#if !os(tvOS)
private struct PageHandoff: ViewModifier {
    let item: JellyfinItem
    @Environment(\.session) private var session
    @Environment(PlayerCoordinator.self) private var player
    /// Under a pushed page or in another tab the page isn't on screen, and the one that is offers itself.
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .userActivity(Handoff.activityType, isActive: isOnScreen && session != nil && !player.coversScreens) { activity in
                guard let session else { return }
                Handoff(link: AppLink(.open, item), signIn: ServerSignIn(session.account)).describe(activity)
            }
    }
}

/// The player makes its activity current itself: SwiftUI's `userActivity(_:isActive:_:)` offers
/// nothing from a full-screen cover, which is where the player is on iPhone and iPad. Making it
/// current again every few seconds also carries the position, and puts the playback ahead of a
/// page that another window offers in the meantime.
private struct PlaybackHandoff: ViewModifier {
    let model: PlayerModel
    @Environment(\.session) private var session

    func body(content: Content) -> some View {
        content
            .task(id: model.item?.id) {
                guard let item = model.item, let session else { return }
                let activity = NSUserActivity(activityType: Handoff.activityType)
                defer { activity.invalidate() }
                while !Task.isCancelled {
                    Handoff(link: AppLink(.play, item, position: model.clock.time), signIn: ServerSignIn(session.account))
                        .describe(activity)
                    activity.becomeCurrent()
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                }
            }
    }
}
#endif
