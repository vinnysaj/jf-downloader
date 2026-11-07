import Foundation
import Observation

/// One person on one Jellyfin server: where the server is and who they are on it, without a
/// token or a password. The password they last signed in with, if any, is in iCloud Keychain under
/// the sign-in's `id` (`Keychain.syncedPassword`).
nonisolated struct ServerSignIn: Codable, Hashable, Identifiable, Sendable {
    var serverId: String
    var serverName: String?
    var address: URL
    var userId: String
    var userName: String

    var id: String { serverId + "/" + userId }

    init(serverId: String, serverName: String?, address: URL, userId: String, userName: String) {
        self.serverId = serverId
        self.serverName = serverName
        self.address = address
        self.userId = userId
        self.userName = userName
    }

    init(_ account: AccountStore.Account) {
        self.init(serverId: account.serverId, serverName: account.serverName, address: account.serverURL,
                  userId: account.userId, userName: account.userName)
    }

    /// The server's name, or its host when it has none.
    var serverTitle: String { serverName ?? address.host() ?? "Jellyfin" }

    /// Whether `account` is this person on this server.
    func isSignedIn(as account: AccountStore.Account?) -> Bool {
        account?.serverId == serverId && account?.userId == userId
    }
}

/// The servers the person has signed in to on any of their devices, kept in iCloud so the sign-in
/// screen of a new device can offer them. Each server is a key of its own, holding everyone who
/// signed in to it, so the latest change on any device wins for that server alone. This device's
/// own sign-in is always among them.
@Observable
final class KnownServers {
    private(set) var signIns: [ServerSignIn] = []
    /// Why a server couldn't be read from iCloud or saved to it, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let cloud: (any CloudKeyValues)?

    nonisolated static let keyPrefix = "server."

    init(accounts: AccountStore, cloud: (any CloudKeyValues)?) {
        self.accounts = accounts
        self.cloud = cloud
        reload()
    }

    /// Remembers each sign-in on this device as it happens.
    func followSignIns() async {
        for await account in Observations({ self.accounts.account }) {
            if let account { remember(account) }
        }
    }

    /// Reads the servers from iCloud, as another device or another Apple Account changed them.
    func reload() {
        guard let cloud else { return }
        let read = Self.signIns(in: cloud.dictionaryRepresentation)
        signIns = read.signIns
        if !read.unreadable.isEmpty {
            problem = "iCloud has servers this version of vinnyfin can't read (\(read.unreadable.joined(separator: ", "))). Updating vinnyfin may help."
        }
        if let account = accounts.account { remember(account) }
    }

    func remember(_ account: AccountStore.Account) {
        let signIn = ServerSignIn(account)
        let server = signIns.filter { $0.serverId == signIn.serverId }
        let remembered = Self.remembering(signIn, on: server)
        guard remembered != server else { return }
        save(remembered, for: signIn.serverId)
    }

    /// Forgets the sign-in on every device, with its password.
    func forget(_ signIn: ServerSignIn) {
        do {
            try Keychain.deleteSyncedPassword(for: signIn.id)
        } catch {
            problem = error.localizedDescription
        }
        save(signIns.filter { $0.serverId == signIn.serverId && $0.userId != signIn.userId }, for: signIn.serverId)
    }

    private func save(_ server: [ServerSignIn], for serverId: String) {
        let key = Self.keyPrefix + serverId
        do {
            if server.isEmpty {
                cloud?.removeObject(forKey: key)
            } else {
                cloud?.set(try JSONEncoder().encode(server), forKey: key)
            }
        } catch {
            problem = "Couldn't save the server to iCloud: \(error.localizedDescription)"
            return
        }
        signIns = Self.sorted(signIns.filter { $0.serverId != serverId } + server)
    }

    /// The sign-ins on a server once `signIn` is among them. The server's address and name are
    /// the latest sign-in's, for everyone on it.
    nonisolated static func remembering(_ signIn: ServerSignIn, on server: [ServerSignIn]) -> [ServerSignIn] {
        let others = server.filter { $0.userId != signIn.userId }.map { other in
            var other = other
            other.address = signIn.address
            other.serverName = signIn.serverName
            return other
        }
        return sorted(others + [signIn])
    }

    /// The sign-ins in iCloud's keys, and the keys that couldn't be read.
    nonisolated static func signIns(in values: [String: Any]) -> (signIns: [ServerSignIn], unreadable: [String]) {
        var signIns: [ServerSignIn] = []
        var unreadable: [String] = []
        for (key, value) in values where key.hasPrefix(keyPrefix) {
            guard let data = value as? Data, let server = try? JSONDecoder().decode([ServerSignIn].self, from: data) else {
                unreadable.append(String(key.dropFirst(keyPrefix.count)))
                continue
            }
            signIns += server
        }
        return (sorted(signIns), unreadable.sorted())
    }

    nonisolated private static func sorted(_ signIns: [ServerSignIn]) -> [ServerSignIn] {
        signIns.sorted {
            ($0.serverTitle.localizedLowercase, $0.userName.localizedLowercase) < ($1.serverTitle.localizedLowercase, $1.userName.localizedLowercase)
        }
    }
}
