import Observation

/// Errors from actions that have no screen of their own (a menu's "Mark as Watched", say),
/// shown as an alert by the root view.
@Observable
final class AppMessages {
    var current: String?

    func show(_ message: String) {
        current = message
    }
}
