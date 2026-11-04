#if os(iOS)
import Observation
import OSLog
import UIKit

/// Keeps the player in the orientation it's watched in once the picture is wide, so watching
/// lying on your side doesn't turn it. Turning the phone the other way offers to rotate instead:
/// the offer shows on its own for a moment, then waits with the controls, and goes away if the
/// phone turns back. iPhone only; iPad windows can't be locked.
@Observable
final class PlayerOrientationLock {
    /// What the app's windows may turn to, as the app delegate tells the system.
    private(set) static var allowed = UIInterfaceOrientationMask.all
    static let announcement: Duration = .seconds(1.5)

    /// The orientation the phone is turned to, which the player can rotate to.
    private(set) var offer: UIInterfaceOrientation?
    /// The offer is new and shows on its own, before it waits with the controls.
    private(set) var isAnnouncing = false

    /// Nil turns with the phone, as until the picture is first wide.
    @ObservationIgnored private var locked: UIInterfaceOrientationMask?
    @ObservationIgnored private var isWide = false
    /// iPhone Duo standing half open turns freely, into the folded layout and back.
    @ObservationIgnored private var isHalfOpen = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var announcing: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.vinnysaj.vinnyfin", category: "player")

    func start() {
        guard UIDevice.current.userInterfaceIdiom == .phone, observer == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceTurned() }
        }
        if let bounds = scene?.effectiveGeometry.coordinateSpace.bounds { isWide = bounds.width > bounds.height }
        relock()
    }

    /// Lets the app turn freely again, as the player closes.
    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        withdraw()
        locked = nil
        apply(.all)
    }

    func windowChanged(isWide: Bool) {
        self.isWide = isWide
        relock()
    }

    func hingeChanged(isHalfOpen: Bool) {
        self.isHalfOpen = isHalfOpen
        relock()
    }

    /// Turns the player the way the phone is turned, and keeps it there.
    func rotate() {
        guard let offer else { return }
        withdraw()
        locked = Self.mask(for: offer)
        apply(Self.mask(for: offer), turning: true)
    }

    // MARK: Following the phone

    private func relock() {
        guard observer != nil else { return }
        if isHalfOpen {
            locked = nil
        } else if locked == nil, isWide, let current = scene?.effectiveGeometry.interfaceOrientation {
            locked = Self.mask(for: current)
        }
        apply(locked ?? .all)
        deviceTurned()
    }

    private func deviceTurned() {
        guard let locked else { return withdraw() }
        // Flat on a table, or unknown: nothing new about which way is up.
        guard let turned = Self.interfaceOrientation(facing: UIDevice.current.orientation) else { return }
        if locked.contains(Self.mask(for: turned)) {
            withdraw()
        } else if offer != turned {
            announce(turned)
        }
    }

    private func announce(_ orientation: UIInterfaceOrientation) {
        offer = orientation
        isAnnouncing = true
        announcing?.cancel()
        announcing = Task {
            try? await Task.sleep(for: Self.announcement)
            if !Task.isCancelled { isAnnouncing = false }
        }
    }

    private func withdraw() {
        announcing?.cancel()
        offer = nil
        isAnnouncing = false
    }

    private func apply(_ mask: UIInterfaceOrientationMask, turning: Bool = false) {
        guard mask != Self.allowed || turning else { return }
        Self.allowed = mask
        guard let scene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        guard turning else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Self.log.error("Couldn't rotate the player: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Both orientations of the same shape, so turning the phone end over end still follows.
    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        orientation.isLandscape ? .landscape : .portrait
    }

    /// The interface orientation that's upright with the device turned this way. Landscape is
    /// mirrored: a device turned left shows its interface turned right.
    private static func interfaceOrientation(facing device: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch device {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
}
#endif
