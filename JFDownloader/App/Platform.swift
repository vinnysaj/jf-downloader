import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum Device {
    /// What people call this device: iPhone, iPad, Apple Vision Pro or Mac.
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

/// Toolbar spots by role. The Mac's window toolbar has no navigation bar, so there they map to
/// its leading and trailing ends.
extension ToolbarItemPlacement {
    static var barLeading: Self {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    static var barTrailing: Self {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }

    /// The screen's main action, kept out of the overflow menu when the bar is narrow, as on
    /// iPhone Duo's outer display.
    static var barPinnedTrailing: Self {
        #if os(macOS)
        .primaryAction
        #else
        .topBarPinnedTrailing
        #endif
    }
}

extension View {
    /// A small title in the bar. The Mac's window toolbar has only the one style.
    func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Where finished files show up, in each platform's words.
enum FinishedFiles {
    #if os(macOS)
    static let browser = "Finder"
    static let place = "Downloads"
    static let hint = "Finished files are in Downloads › JF Downloader. Open them in Infuse from there."

    /// Finder opens a folder's file URL.
    static func browserURL(for folder: URL) -> URL { folder }
    #else
    static let browser = "Files"
    static let place = "Files"
    static var hint: String {
        "Finished files are in the Files app under On My \(Device.name) › JF Downloader. Move or share them into Infuse from there."
    }

    /// Opens the Files app at a folder of this app's Documents.
    static func browserURL(for folder: URL) -> URL {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = folder.path
        return components.url ?? folder
    }
    #endif
}
