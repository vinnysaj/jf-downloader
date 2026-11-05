import Foundation
import Observation

/// Links into the app from outside its windows: a tapped notification, Siri, Shortcuts and
/// Spotlight's results. The root view takes each and follows it as it does a vinnyfin:// URL the
/// system opens, launching the app or not.
@Observable
final class IncomingLinks {
    /// The link to follow, until the root view takes it.
    var pending: URL?

    func open(_ url: URL) {
        pending = url
    }

    func open(_ link: AppLink) {
        open(link.url)
    }
}
