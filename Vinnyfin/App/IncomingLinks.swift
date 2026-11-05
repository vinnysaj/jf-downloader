import Foundation
import Observation

/// Links into the app from outside its windows: a tapped notification, Siri, Shortcuts,
/// Spotlight's results and Handoff. The root view takes each and follows it as it does a
/// vinnyfin:// URL the system opens, launching the app or not.
@Observable
final class IncomingLinks {
    nonisolated enum Incoming: Equatable, Sendable {
        case link(URL)
        #if !os(tvOS)
        /// A title another of the person's devices handed off, with the sign-in it's from, which
        /// this device may not have.
        case handoff(Handoff)
        #endif
    }

    /// What to follow, until the root view takes it.
    var pending: Incoming?

    func open(_ url: URL) {
        pending = .link(url)
    }

    func open(_ link: AppLink) {
        open(link.url)
    }

    #if !os(tvOS)
    func open(_ handoff: Handoff) {
        pending = .handoff(handoff)
    }
    #endif
}
