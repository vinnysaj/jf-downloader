import Foundation
import Observation
import Security

/// Who is signed in to which server. The token lives in the Keychain, readable after the
/// first unlock so downloads can carry on while the phone is locked.
@Observable
final class AccountStore {
    struct Account: Codable, Equatable {
        var serverURL: URL
        var serverId: String
        var serverName: String?
        var userId: String
        var userName: String
    }

    private(set) var account: Account?
    private(set) var client: JellyfinClient?

    private let defaults: UserDefaults
    private static let accountKey = "account"
    private static let deviceIdKey = "deviceId"
    private static let lastServerKey = "lastServer"
    private static let lastUserNameKey = "lastUserName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.accountKey),
           let account = try? JSONDecoder().decode(Account.self, from: data),
           let token = Keychain.token(for: account.serverId)
        {
            self.account = account
            client = JellyfinClient(serverURL: account.serverURL, deviceId: deviceId, deviceName: Device.name, token: token)
        }
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
        try await JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.name).publicSystemInfo()
    }

    func signIn(serverURL: URL, username: String, password: String) async throws {
        let client = JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.name)
        let info = try await client.publicSystemInfo()
        let result = try await client.authenticate(username: username, password: password)
        try adopt(result, serverURL: serverURL, info: info, client: client)
        defaults.set(username, forKey: Self.lastUserNameKey)
    }

    /// Starts a Quick Connect sign-in: the code is entered in an app that is already signed in.
    func startQuickConnect(serverURL: URL) async throws -> QuickConnectState {
        let client = JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.name)
        guard try await client.quickConnectEnabled() else { throw JellyfinError.quickConnectDisabled }
        return try await client.initiateQuickConnect()
    }

    /// Waits for the code to be approved, then signs in. Ends when the calling task is cancelled.
    func finishQuickConnect(serverURL: URL, secret: String) async throws {
        let client = JellyfinClient(serverURL: serverURL, deviceId: deviceId, deviceName: Device.name)
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
        defaults.set(try JSONEncoder().encode(account), forKey: Self.accountKey)
        defaults.set(serverURL, forKey: Self.lastServerKey)
        self.account = account
        self.client = client
    }

    func signOut() async {
        if let client {
            // The session ends locally either way; a server that can't be reached just keeps a stale token.
            try? await client.signOut()
        }
        if let account { Keychain.deleteToken(for: account.serverId) }
        defaults.removeObject(forKey: Self.accountKey)
        account = nil
        client = nil
    }
}

nonisolated enum Keychain {
    private static let service = "net.vinnysaj.vinnyfin.token"

    static func token(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for account: String) throws {
        deleteToken(for: account)
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't save the sign-in to the Keychain (\(status)).",
            ])
        }
    }

    static func deleteToken(for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
