import SwiftUI

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
    /// The screen's title in the navigation bar, except on Apple TV. There the bar stays over the
    /// content as it scrolls, so a title in it sits on whatever scrolls under; the sidebar names
    /// each tab's first screen, and other screens head their content with their title. Hiding
    /// the bar instead hangs the app when a screen that hides it is pushed.
    func screenTitle(_ title: some StringProtocol) -> some View {
        #if os(tvOS)
        self
        #else
        navigationTitle(title)
        #endif
    }

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
    #if os(tvOS)
    /// A search field that's always on screen.
    func alwaysSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        searchable(text: text, prompt: prompt)
    }
    #else
    /// A search field that's always on screen. On iPhone, a search tab's field placed
    /// automatically never appears: neither in the navigation bar nor in the tab bar. `isActive`
    /// is whether it has the cursor, and setting it puts the cursor there.
    func alwaysSearchable(text: Binding<String>, isActive: Binding<Bool>, prompt: LocalizedStringKey) -> some View {
        #if os(iOS)
        searchable(text: text, isPresented: isActive, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        searchable(text: text, isPresented: isActive, prompt: prompt)
        #endif
    }
    #endif
}

/// A vertical scroll view whose artwork and rows run the whole width: past Apple TV's overscan
/// margin, and elsewhere under the bars at the sides, like iPad's sidebar and iPhone Duo's
/// vertical bar, and up under the bars over the top when `underTopBars`. At the sides the view and
/// its content keep to the safe area: what's laid over the view, and the content's text and
/// controls, `Metrics.edge` in, stay clear of the bars, while artwork runs under them with
/// `ignoresSafeArea(edges: .horizontal)` and rows of cards scroll under them on their own. Over the
/// top, content keeps clear of the bars with `topBarsHeight`. Apple TV's overscan margin isn't a
/// bar: there the content runs to the screen's edges, and it and what's laid over the view keep to
/// `Metrics.edge`.
struct EdgeToEdgeScrollView<Content: View>: View {
    /// Runs up under the bars over the top, as a page does whose artwork starts at the screen's top.
    var underTopBars = false
    @ViewBuilder let content: Content
    #if !os(tvOS)
    /// How far the bars over the top reach, the only inset measured. Artwork can run up under
    /// those bars only when the scroll view gives that part of the safe area up, and then nothing
    /// inside it knows where they end. At the sides the safe area does the work instead: measuring
    /// a side's inset and padding content by it hangs iPhone Duo's outer display, whose vertical
    /// bar moves by a fraction of a point with the content beside it.
    @State private var topBarsHeight: CGFloat = 0
    #endif

    var body: some View {
        #if os(tvOS)
        ScrollView { content }
            .ignoresSafeArea(edges: edges)
        #else
        ScrollView { content.environment(\.topBarsHeight, underTopBars ? topBarsHeight : 0) }
            .ignoresSafeArea(edges: edges)
            // Measured outside the edge given up: inside, the bars would read as none at all.
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topBarsHeight = $0 }
        #endif
    }

    /// The parts of the safe area the scroll view gives up: Apple TV's overscan margin at the
    /// sides, and the bars over the top when `underTopBars`.
    private var edges: Edge.Set {
        #if os(tvOS)
        underTopBars ? [.horizontal, .top] : .horizontal
        #else
        underTopBars ? .top : []
        #endif
    }
}

extension EnvironmentValues {
    /// How far the bars over the top of an `EdgeToEdgeScrollView` that runs up under them reach
    /// over its content; zero in one that doesn't.
    @Entry var topBarsHeight: CGFloat = 0
}
