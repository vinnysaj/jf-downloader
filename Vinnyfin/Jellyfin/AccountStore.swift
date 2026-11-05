import Foundation
import Observation
import OSLog

/// Who is signed in to which server. The token lives in the `Keychain`. On Apple TV, iPhone, iPad
/// and the Mac the sign-in is kept in the app group, where the app's extensions read it to ask
/// the server what's up next: Apple TV's Top Shelf, and the Up Next widgets.
@Observable
final class AccountStore {
    nonisolated struct Account: Codable, Equatable, Sendable {
        var serverURL: URL
        var serverId: String
        var serverName: String?
        var userId: String
        var userName: String

        /// What to call the server in a sentence.
        var serverTitle: String { serverName ?? serverURL.host() ?? "the server" }
    }

    private(set) var account: Account?
    private(set) var client: JellyfinClient?
    /// Why the sign-in saved here can't be used: its token isn't in the Keychain, or the Keychain
    /// wouldn't give it. Nil when there's none saved, or it's in use.
    private(set) var savedSignInProblem: String?
    #if os(iOS) || os(macOS)
    /// Why the sign-in couldn't be moved where the widgets read it. The app stays signed in.
    private(set) var sharingProblem: String?
    #endif

    private let defaults: UserDefaults
    nonisolated private static let accountKey = "account"
    nonisolated private static let deviceIdKey = "deviceId"
    nonisolated private static let lastServerKey = "lastServer"
    nonisolated private static let lastUserNameKey = "lastUserName"
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "accounts")

    /// Where the sign-in is kept: on Apple TV, iPhone, iPad and the Mac the app group's defaults,
    /// shared with the app's extensions.
    nonisolated static var savedDefaults: UserDefaults {
        #if os(visionOS)
        .standard
        #else
        // A suite is refused only when it's named after the app itself.
        UserDefaults(suiteName: AppGroup.identifier)!
        #endif
    }

    /// The sign-in saved in `defaults`, as an extension reads it.
    convenience init(defaults: UserDefaults = savedDefaults) {
        self.init(defaults: defaults) { try Keychain.token(for: $0) }
    }

    private init(defaults: UserDefaults, token: (_ serverId: String) throws -> String?) {
        self.defaults = defaults
        do {
            guard let account = try Self.savedAccount(in: defaults) else { return }
            guard let token = try token(account.serverId) else {
                savedSignInProblem = "The sign-in to \(account.serverTitle) isn't in the Keychain."
                return
            }
            self.account = account
            client = JellyfinClient(serverURL: account.serverURL, deviceId: deviceId, deviceName: Device.ownName, token: token)
        } catch {
            Self.log.error("Couldn't read the saved sign-in: \(error.localizedDescription, privacy: .public)")
            savedSignInProblem = error.localizedDescription
        }
    }

    #if os(iOS) || os(macOS)
    /// The app's sign-in, moved first from where only the app reads it to the app group, for the
    /// widgets. While it can't be moved, the app keeps it where it is for this run: in its own
    /// defaults, with its own Keychain item, or the group's for a sign-in saved since.
    convenience init(movingSignInFrom appDefaults: UserDefaults) {
        let moveError: (any Error)?
        do {
            try Self.moveSignInToAppGroup(from: appDefaults, to: Self.savedDefaults)
            moveError = nil
        } catch {
            moveError = error
        }
        guard let moveError else {
            self.init(defaults: Self.savedDefaults)
            return
        }
        Self.log.error("Couldn't move the sign-in to the app group: \(moveError.localizedDescription, privacy: .public)")
        self.init(defaults: appDefaults) { serverId in
            try Keychain.appToken(for: serverId) ?? Keychain.token(for: serverId)
        }
        sharingProblem = "The widgets can't use your sign-in: \(moveError.localizedDescription) vinnyfin stays signed in and tries again the next time it opens."
    }
    #endif

    nonisolated private static func savedAccount(in defaults: UserDefaults) throws -> Account? {
        guard let data = defaults.data(forKey: accountKey) else { return nil }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    /// The signed-in server and user, for browsing.
    var session: ServerSession? {
        guard let client, let account else { return nil }
        return ServerSession(client: client, account: account)
    }

    /// Identifies this install to the server; Jellyfin lists sessions by it.
    var deviceId: String {
        if let id = defaults.string(forKey: Self.deviceIdKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.deviceIdKey)
        return id
    }

    /// The server and user of the last sign-in, to fill in the form after signing out.
    var lastServerURL: URL? { defaults.url(forKey: Self.lastServerKey) }
    var lastUserName: String? { defaults.string(forKey: Self.lastUserNameKey) }

    /// Checks that a Jellyfin server answers at the address, without signing in.
    func probe(_ serverURL: URL) async throws -> PublicSystemInfo {
        try await JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.ownName).publicSystemInfo()
    }

    func signIn(serverURL: URL, username: String, password: String) async throws {
        let client = JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.ownName)
        let info = try await client.publicSystemInfo()
        let result = try await client.authenticate(username: username, password: password)
        try adopt(result, serverURL: serverURL, info: info, client: client)
        defaults.set(username, forKey: Self.lastUserNameKey)
    }

    /// Starts a Quick Connect sign-in: the code is entered in an app that is already signed in.
    func startQuickConnect(serverURL: URL) async throws -> QuickConnectState {
        let client = JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.ownName)
        guard try await client.quickConnectEnabled() else { throw JellyfinError.quickConnectDisabled }
        return try await client.initiateQuickConnect()
    }

    /// Waits for the code to be approved, then signs in. Ends when the calling task is cancelled.
    func finishQuickConnect(serverURL: URL, secret: String) async throws {
        let client = JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.ownName)
        let info = try await client.publicSystemInfo()
        while try await !client.quickConnectState(secret: secret).authenticated {
            try await Task.sleep(for: .seconds(2))
        }
        let result = try await client.authenticate(quickConnectSecret: secret)
        try adopt(result, serverURL: serverURL, info: info, client: client)
        defaults.set(result.user.name, forKey: Self.lastUserNameKey)
    }

    private func adopt(_ result: AuthenticationResult, serverURL: URL, info: PublicSystemInfo, client: JellyfinClient) throws {
        var client = client
        client.token = result.accessToken
        let account = Account(
            serverURL: serverURL,
            serverId: result.serverId,
            serverName: info.serverName,
            userId: result.user.id,
            userName: result.user.name
        )
        try Keychain.setToken(result.accessToken, for: account.serverId)
        #if os(iOS) || os(macOS)
        // The next launch's move would take a token left where only the app read it for newer.
        try Keychain.deleteAppToken(for: account.serverId)
        #endif
        defaults.set(try JSONEncoder().encode(account), forKey: Self.accountKey)
        defaults.set(serverURL, forKey: Self.lastServerKey)
        self.account = account
        self.client = client
        savedSignInProblem = nil
    }

    func signOut() async {
        if let client {
            // The session ends locally either way; a server that can't be reached just keeps a stale token.
            try? await client.signOut()
        }
        if let account {
            do {
                try Keychain.deleteToken(for: account.serverId)
                #if os(iOS) || os(macOS)
                // Where the token stays while it can't be moved to the app group.
                try Keychain.deleteAppToken(for: account.serverId)
                #endif
            } catch {
                Self.log.error("Couldn't delete the token of \(account.serverTitle, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        defaults.removeObject(forKey: Self.accountKey)
        account = nil
        client = nil
    }
}

#if os(iOS) || os(macOS)
// MARK: Sharing the sign-in with the widgets

extension AccountStore {
    /// What the sign-in keeps in defaults, all of it moved to the app group.
    nonisolated static let sharedKeys = [accountKey, deviceIdKey, lastServerKey, lastUserNameKey]

    /// Moves a sign-in kept where only the app reads it, its own defaults and Keychain item, to
    /// the app group. It runs at each launch and does nothing once everything has moved.
    static func moveSignInToAppGroup(from appDefaults: UserDefaults, to sharedDefaults: UserDefaults) throws {
        try moveSignIn(from: appDefaults, to: sharedDefaults, isInAppGroup: AppGroup.container != nil) { serverId in
            try moveToken(
                read: { try Keychain.appToken(for: serverId) },
                readShared: { try Keychain.token(for: serverId) },
                writeShared: { try Keychain.setToken($0, for: serverId) },
                deleteOriginal: { try Keychain.deleteAppToken(for: serverId) }
            )
        }
    }

    /// Moves the token of the sign-in first, the app's own if it has one, then the defaults, and
    /// those only once the group has proven itself. A build the group isn't granted to, as one
    /// built without signing or a Mac app whose profile lacks the group, has no container on
    /// iPhone and iPad, and the Keychain refuses it the group everywhere; its group defaults are
    /// a file of the app's own, which a build that has the group never reads, so a sign-in moved
    /// there would be lost to it.
    nonisolated static func moveSignIn(from appDefaults: UserDefaults, to sharedDefaults: UserDefaults, isInAppGroup: Bool,
                                       movingToken: (_ serverId: String) throws -> Void) throws {
        guard isInAppGroup else { throw SignInMoveError.notInAppGroup }
        if let account = try savedAccount(in: appDefaults) ?? savedAccount(in: sharedDefaults) {
            try movingToken(account.serverId)
        }
        moveDefaults(from: appDefaults, to: sharedDefaults)
    }

    /// Moves each of the sign-in's values in the app's own defaults to the group's. Anything left
    /// in the app's own was written there after an earlier move, by a build that kept it there,
    /// so it replaces what the group holds.
    nonisolated static func moveDefaults(from appDefaults: UserDefaults, to sharedDefaults: UserDefaults) {
        for key in sharedKeys {
            guard let value = appDefaults.object(forKey: key) else { continue }
            sharedDefaults.set(value, forKey: key)
            appDefaults.removeObject(forKey: key)
        }
    }

    /// Copies the token from where it is to the shared place, unless it's there already, reads the
    /// copy back, and deletes the original only once the copy reads back the same.
    nonisolated static func moveToken(read: () throws -> String?, readShared: () throws -> String?,
                                      writeShared: (String) throws -> Void, deleteOriginal: () throws -> Void) throws {
        guard let token = try read() else { return }
        if try readShared() != token {
            try writeShared(token)
            guard try readShared() == token else { throw SignInMoveError.copyDiffers }
        }
        try deleteOriginal()
    }
}

nonisolated enum SignInMoveError: LocalizedError {
    case notInAppGroup
    case copyDiffers

    var errorDescription: String? {
        switch self {
        case .notInAppGroup: "This build of vinnyfin isn't in the app group \(AppGroup.identifier)."
        case .copyDiffers: "The Keychain's copy of the sign-in didn't read back the same."
        }
    }
}
#endif
