import Foundation

/// The app group the app shares with its extensions: on Apple TV the Top Shelf, and on iPhone,
/// iPad and the Mac the widgets. Both read the sign-in from it (`AccountStore`, whose token the
/// group's Keychain access group holds); the Downloads widget also reads the snapshot the app
/// writes there (`DownloadsSnapshot`).
nonisolated enum AppGroup {
    static let identifier = "group.net.vinnysaj.vinnyfin"

    /// The group's folder. Nil when the build isn't entitled to the group.
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
