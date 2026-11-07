import Foundation
import Security

/// The sign-in tokens, one generic password per server, readable after the first unlock so
/// downloads carry on while the device is locked. On Apple TV, iPhone, iPad and the Mac they're
/// kept in the app group, which doubles as a Keychain access group, so the app's extensions read
/// them too: the Top Shelf and the Up Next widgets. On the Mac access groups are the data
/// protection keychain's, and the app group must be authorized by the provisioning profile for
/// that keychain to honor it. Vision Pro, with no extensions, keeps them in the app's own group.
///
/// The passwords signed in with are kept too, in iCloud Keychain, so the person's other devices
/// sign in without asking for them (`syncedPassword`).
nonisolated enum Keychain {
    private static let service = "net.vinnysaj.vinnyfin.token"
    private static let passwordService = "net.vinnysaj.vinnyfin.password"

    /// The server's token; nil when there's none.
    static func token(for account: String) throws -> String? {
        try readToken(sharedQuery(account))
    }

    static func setToken(_ token: String, for account: String) throws {
        try deleteToken(for: account)
        var query = sharedQuery(account)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(query as CFDictionary, nil), "Couldn't save the sign-in to the Keychain")
    }

    static func deleteToken(for account: String) throws {
        try delete(sharedQuery(account))
    }

    private static func sharedQuery(_ account: String) -> [String: Any] {
        var query = baseQuery(account)
        #if !os(visionOS)
        query[kSecAttrAccessGroup as String] = AppGroup.identifier
        #endif
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    #if os(iOS) || os(macOS)
    // MARK: Where only the app reads them

    /// A token where only the app reads it: in its own access group on iPhone and iPad, and in
    /// the login keychain on the Mac. Sign-ins saved before the widgets could read them are there
    /// until the app moves them to the app group (`AccountStore.moveSignInToAppGroup`).
    static func appToken(for account: String) throws -> String? {
        guard let query = try appQuery(account) else { return nil }
        return try readToken(query)
    }

    static func deleteAppToken(for account: String) throws {
        guard let query = try appQuery(account) else { return }
        try delete(query)
    }

    /// The query that finds the app's own item for the server, or nil when it has none. On the
    /// Mac it names the login keychain: macOS 27 takes a query that names neither for the data
    /// protection keychain's, which finds the app group's item, and deleting the app's own then
    /// signs the app out at every launch. On iPhone and iPad a query without an access group
    /// searches every group the app is in, the app group among them, so it's narrowed to the group
    /// of the item outside the app group.
    private static func appQuery(_ account: String) throws -> [String: Any]? {
        #if os(macOS)
        var query = baseQuery(account)
        query[kSecUseDataProtectionKeychain as String] = false
        return query
        #else
        var search = baseQuery(account)
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "Couldn't look for the sign-in in the Keychain")
        let groups = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccessGroup as String] as? String }
        guard let group = groups.first(where: { $0 != AppGroup.identifier }) else { return nil }
        var query = baseQuery(account)
        query[kSecAttrAccessGroup as String] = group
        return query
        #endif
    }
    #endif

    // MARK: Passwords in iCloud Keychain

    /// The password someone last signed in to a server with on any of their devices, by the
    /// `ServerSignIn.id` of who they are there; nil when there's none, as after Quick Connect.
    /// Each device signs in with it for a token of its own, so the server tells them apart.
    static func syncedPassword(for signIn: String) throws -> String? {
        try readToken(passwordQuery(signIn))
    }

    static func setSyncedPassword(_ password: String, for signIn: String) throws {
        try deleteSyncedPassword(for: signIn)
        var query = passwordQuery(signIn)
        query[kSecValueData as String] = Data(password.utf8)
        // An item that syncs can't be kept to this device alone.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        try check(SecItemAdd(query as CFDictionary, nil), "Couldn't save the password to iCloud Keychain")
    }

    /// Deletes the password on every device.
    static func deleteSyncedPassword(for signIn: String) throws {
        try delete(passwordQuery(signIn))
    }

    /// In the app's own access group, its app ID's, the first of its groups and the same on
    /// every platform, so iCloud Keychain carries it to the app on each of them.
    private static func passwordQuery(_ signIn: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordService,
            kSecAttrAccount as String: signIn,
            kSecAttrSynchronizable as String: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    // MARK: Plumbing

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readToken(_ query: [String: Any]) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "Couldn't read the sign-in from the Keychain")
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(message: "The Keychain's sign-in isn't readable text.", status: errSecDecode)
        }
        return token
    }

    private static func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, "Couldn't delete the sign-in from the Keychain")
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        guard status != errSecSuccess else { return }
        throw KeychainError(message: message, status: status)
    }
}

/// A Keychain call that failed, with what the system says the status means.
nonisolated struct KeychainError: LocalizedError, Equatable {
    let message: String
    let status: OSStatus

    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
        return "\(message): \(reason) (\(status))."
    }
}
