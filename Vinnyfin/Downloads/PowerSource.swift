#if !os(tvOS)
import Foundation
#if os(macOS)
import IOKit.ps
import notify
#else
import UIKit
#endif

/// Whether the device is on external power, for Only While Charging, and when that changes.
/// Plugged in counts whether or not the battery is still charging, as the system's own
/// "requires external power" does.
enum PowerSource {
    /// Nil when the device can't say, which the Simulator can't.
    static var isExternal: Bool? {
        #if os(macOS)
        // Unlimited time remaining means a power adapter, or a Mac without a battery.
        IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
        #else
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        case .unplugged: false
        case .unknown: nil
        @unknown default: nil
        }
        #endif
    }

    /// Yields each time the power source may have changed, for as long as it's iterated.
    static func changes() -> AsyncStream<Void> {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        #if os(macOS)
        var token: Int32 = 0
        guard notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main, { _ in continuation.yield() }) == NOTIFY_STATUS_OK else {
            continuation.finish()
            return changes
        }
        let registered = token
        continuation.onTermination = { _ in notify_cancel(registered) }
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let observation = NotificationCenter.default.addObserver(of: UIDevice.current, for: .batteryStateDidChange) { _ in
            continuation.yield()
        }
        continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observation) }
        #endif
        return changes
    }
}
#endif
