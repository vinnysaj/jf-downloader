import AppIntents
import SwiftUI
import WidgetKit

/// A switch for Control Center, the Lock Screen and the Action button that pauses every download
/// or runs them again. It's on while anything is downloading or waiting its turn.
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
        return snapshot.unfinishedCount == 0 ? "None" : "Paused"
    }

    private static func symbol(of snapshot: DownloadsSnapshot, isOn: Bool) -> String {
        if isOn { return "arrow.down.circle.fill" }
        return snapshot.unfinishedCount == 0 ? "arrow.down.circle" : "pause.circle"
    }

    struct Provider: ControlValueProvider {
        var previewValue: DownloadsSnapshot { DownloadsSnapshot() }

        func currentValue() async throws -> DownloadsSnapshot {
            try DownloadsSnapshot.load() ?? DownloadsSnapshot()
        }
    }
}
