import AppIntents
import SwiftUI
import WidgetKit

/// A switch for Control Center, the Lock Screen and the Action button that pauses every download
/// or resumes the paused ones, as Pause All and Resume All do. It's on while anything is
/// downloading or waiting its turn. Downloads that stopped on a failure wait for Retry in the
/// app, which it says when they're all there is.
struct DownloadsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: DownloadsSnapshot.controlKind, provider: Provider()) { snapshot in
            ControlWidgetToggle(isOn: snapshot.isRunning, action: SetDownloadsRunningIntent()) {
                Label("Downloads", systemImage: "arrow.down.circle")
            } valueLabel: { isOn in
                Label(Self.state(of: snapshot, isOn: isOn), systemImage: Self.symbol(of: snapshot, isOn: isOn))
            }
        }
        .displayName("Downloads")
        .description("Pauses vinnyfin's downloads, or resumes them.")
    }

    private static func state(of snapshot: DownloadsSnapshot, isOn: Bool) -> String {
        if isOn { return snapshot.activeCount == 1 ? "1 Downloading" : "\(snapshot.activeCount) Downloading" }
        if snapshot.unfinishedCount == 0 { return "None" }
        return snapshot.stoppedCount == snapshot.unfinishedCount ? "Stopped" : "Paused"
    }

    private static func symbol(of snapshot: DownloadsSnapshot, isOn: Bool) -> String {
        if isOn { return "arrow.down.circle.fill" }
        if snapshot.unfinishedCount == 0 { return "arrow.down.circle" }
        return snapshot.stoppedCount == snapshot.unfinishedCount ? "exclamationmark.circle" : "pause.circle"
    }

    struct Provider: ControlValueProvider {
        var previewValue: DownloadsSnapshot { DownloadsSnapshot() }

        func currentValue() async throws -> DownloadsSnapshot {
            try DownloadsSnapshot.load() ?? DownloadsSnapshot()
        }
    }
}
