import SwiftUI
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

/// Toolbar spots by role. The Mac's window toolbar has no navigation bar, so there they map to
/// its leading and trailing ends.
extension ToolbarItemPlacement {
    static var barLeading: Self {
        #if os(macOS) || os(tvOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    static var barTrailing: Self {
        #if os(macOS) || os(tvOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }

    /// The screen's main action, kept out of the overflow menu when the bar is narrow, as on
    /// iPhone Duo's outer display.
    static var barPinnedTrailing: Self {
        #if os(macOS) || os(tvOS)
        .primaryAction
        #else
        .topBarPinnedTrailing
        #endif
    }
}

extension View {
    /// A small title in the bar. The Mac's window toolbar and Apple TV have only the one style.
    func inlineNavigationTitle() -> some View {
        #if os(macOS) || os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Where finished downloads show up, in each platform's words.
enum FinishedFiles {
    #if os(macOS)
    static let browser = "Finder"
    static let place = "Downloads"
    static let hint = "Downloads are saved in Downloads › vinnyfin, where other apps can open them too."

    /// Finder opens a folder's file URL.
    static func browserURL(for folder: URL) -> URL { folder }
    #else
    static let browser = "Files"
    static let place = "Files"
    static var hint: String {
        "Downloads are saved in the Files app under On My \(Device.name) › vinnyfin, where other apps can open them too."
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

/// Liquid Glass where the system has it. Vision Pro draws all its controls on its own glass
/// material instead, which its standard bordered styles already use.
#if os(visionOS)
typealias PlatformGlassButtonStyle = BorderedButtonStyle
typealias PlatformGlassProminentButtonStyle = BorderedProminentButtonStyle
#else
typealias PlatformGlassButtonStyle = GlassButtonStyle
typealias PlatformGlassProminentButtonStyle = GlassProminentButtonStyle
#endif

extension PrimitiveButtonStyle where Self == PlatformGlassButtonStyle {
    static var platformGlass: Self {
        #if os(visionOS)
        .bordered
        #else
        .glass
        #endif
    }
}

extension PrimitiveButtonStyle where Self == PlatformGlassProminentButtonStyle {
    static var platformGlassProminent: Self {
        #if os(visionOS)
        .borderedProminent
        #else
        .glassProminent
        #endif
    }
}

extension View {
    func platformGlass(in shape: some InsettableShape) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: shape)
        #else
        glassEffect(.regular, in: shape)
        #endif
    }
}

/// For artwork cards: Apple TV lifts them under focus; elsewhere they stay untinted, with the
/// title in the text color rather than the accent.
#if os(tvOS)
typealias ArtworkButtonStyle = BorderlessButtonStyle
#else
typealias ArtworkButtonStyle = PlainButtonStyle
#endif

extension PrimitiveButtonStyle where Self == ArtworkButtonStyle {
    static var artwork: Self {
        #if os(tvOS)
        .borderless
        #else
        .plain
        #endif
    }
}

extension View {
    /// Scrolling screens run the whole width, so artwork and rows go past the TV's overscan
    /// margin, an iPhone's landscape insets and under iPhone Duo's vertical bar, which floats
    /// over them like any bar.
    func scrollsEdgeToEdge() -> some View {
        #if os(macOS)
        self
        #else
        ignoresSafeArea(edges: .horizontal)
        #endif
    }

    /// A search field that's always on screen. On iPhone, a search tab's field placed
    /// automatically never appears: neither in the navigation bar nor in the tab bar.
    func alwaysSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }
}
