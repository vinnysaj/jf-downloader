import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum Device {
    /// What people call this device: iPhone, iPad, Apple TV, Apple Vision Pro or Mac.
    static var name: String {
        #if os(macOS)
        "Mac"
        #elseif os(visionOS)
        "Apple Vision Pro"
        #else
        UIDevice.current.model
        #endif
    }

    /// This device's own name, which the server shows in its device list and other apps show when
    /// they offer to play here: the Mac's computer name; elsewhere the name given in Settings
    /// when the app has the User-Assigned Device Name entitlement, and the model's without it.
    static let ownName: String = {
        #if os(macOS)
        Host.current().localizedName ?? name
        #else
        UIDevice.current.name
        #endif
    }()

    nonisolated enum Platform: String, Sendable {
        case iOS, tvOS, macOS, visionOS

        static var current: Platform {
            #if os(macOS)
            .macOS
            #elseif os(tvOS)
            .tvOS
            #elseif os(visionOS)
            .visionOS
            #else
            .iOS
            #endif
        }
    }
}
