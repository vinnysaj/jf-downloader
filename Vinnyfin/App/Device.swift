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
}
