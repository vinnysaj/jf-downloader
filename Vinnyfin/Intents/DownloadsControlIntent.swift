#if os(iOS) || os(macOS)
import AppIntents

/// Runs and pauses every download for the Downloads control. The app's `WidgetDownloads` is
/// this; the widget extension, which compiles the control's intent too, has none.
@MainActor
protocol DownloadsRunning: AnyObject, Sendable {
    /// Runs or pauses every download, and returns once the control and widget can show it.
    func setRunning(_ isRunning: Bool) async
}

/// Runs or pauses every download, as the Downloads control's switch does. The control shows in
/// the widget extension, which only draws it: the intent runs in the app, where the downloads
/// are, which the system launches in the background when it isn't running.
struct SetDownloadsRunningIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Run or Pause Downloads"
    static let isDiscoverable = false
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Downloading")
    var value: Bool

    @Dependency private var downloads: any DownloadsRunning

    @MainActor
    func perform() async throws -> some IntentResult {
        await downloads.setRunning(value)
        return .result()
    }
}
#endif
