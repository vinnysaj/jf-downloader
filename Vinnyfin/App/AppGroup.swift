import Foundation

/// The app group the app shares with its extensions: on Apple TV the Top Shelf, which reads the
/// sign-in from it; on iPhone, iPad and the Mac the Downloads widget, which reads the snapshot
/// the app writes there (`DownloadsSnapshot`).
nonisolated enum AppGroup {
    static let identifier = "group.net.vinnysaj.vinnyfin"

    /// The group's folder. Nil when the build isn't entitled to the group.
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
