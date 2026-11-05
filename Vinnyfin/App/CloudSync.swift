import Foundation
import OSLog

/// iCloud's key-value store, as the settings and the known servers keep their values in it.
protocol CloudKeyValues: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
}

extension NSUbiquitousKeyValueStore: CloudKeyValues {}

/// Keeps the settings and the servers signed in to the same on all the person's devices,
/// through iCloud's key-value store. Every setting and every server is a key of its own, and
/// iCloud keeps the latest change to each key, from whichever device made it. On a shared Apple
/// TV each person has their own iCloud, and so their own settings and servers.
final class CloudSync {
    private let store: NSUbiquitousKeyValueStore
    private let settings: AppSettings
    private let servers: KnownServers
    private let messages: AppMessages

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "icloud")

    init(store: NSUbiquitousKeyValueStore, settings: AppSettings, servers: KnownServers, messages: AppMessages) {
        self.store = store
        self.settings = settings
        self.servers = servers
        self.messages = messages
    }

    /// Takes what changed in iCloud while the app wasn't running, then each change as it comes.
    func run() async {
        if !store.synchronize() {
            Self.log.notice("iCloud's key-value store isn't available, so settings and servers stay on this device")
        }
        settings.reconcileWithCloud()
        servers.reload()
        let changes = NotificationCenter.default.notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
        for await notification in changes where notification.object as AnyObject? === store {
            guard let change = CloudChange(userInfo: notification.userInfo) else { continue }
            Self.log.info("iCloud changed: \(String(describing: change), privacy: .public)")
            switch change {
            case .changed(let keys):
                settings.cloudChanged(keys)
                servers.reload()
            case .replaced:
                settings.reconcileWithCloud()
                servers.reload()
            case .full:
                messages.show("iCloud has no more room for vinnyfin's settings and servers, so what changes on this \(Device.name) stays on it.")
            }
        }
    }
}

/// What iCloud's key-value store says changed, from its notification.
nonisolated enum CloudChange: Equatable, Sendable {
    /// Another device changed these keys.
    case changed([String])
    /// iCloud replaced the store's keys with its own: on its first download to this device, or
    /// for another Apple Account.
    case replaced
    /// The store is over its quota, and iCloud takes no more.
    case full

    /// Nil when the notification doesn't say why.
    init?(userInfo: [AnyHashable: Any]?) {
        guard let reason = userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else { return nil }
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange:
            self = .changed(userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? [])
        case NSUbiquitousKeyValueStoreInitialSyncChange, NSUbiquitousKeyValueStoreAccountChange:
            self = .replaced
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            self = .full
        default:
            return nil
        }
    }
}

/// How this device's settings and iCloud's come together when iCloud hands over a whole store: at
/// launch, on its first download to this device, and for another Apple Account. iCloud's value
/// wins for each setting it has, since every change made here goes to iCloud as it's made; a
/// setting iCloud doesn't have yet, chosen before the settings followed the person, goes up.
nonisolated struct SettingsMerge {
    /// The values to take from iCloud.
    var adopted: [String: Any] = [:]
    /// The values to send to iCloud.
    var uploaded: [String: Any] = [:]

    init(local: [String: Any], cloud: [String: Any], syncs: (String) -> Bool) {
        for (key, value) in cloud where syncs(key) {
            if !Self.same(local[key], value) { adopted[key] = value }
        }
        for (key, value) in local where syncs(key) && cloud[key] == nil {
            uploaded[key] = value
        }
    }

    /// Property-list values, compared as Foundation compares them.
    static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return lhs == nil && rhs == nil }
        return lhs.isEqual(rhs)
    }
}
