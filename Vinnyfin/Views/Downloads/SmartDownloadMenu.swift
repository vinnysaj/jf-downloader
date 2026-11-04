#if !os(tvOS)
import SwiftUI

/// The ways to keep a show downloaded, as a menu: the next few episodes, or every unwatched one,
/// which first says how much space that takes; and a way to stop. `downloadNow` goes above them,
/// for one-off downloads.
struct SmartDownloadMenu<DownloadNow: View, MenuLabel: View>: View {
    let seriesId: String
    let seriesName: String
    @ViewBuilder var downloadNow: () -> DownloadNow
    @ViewBuilder var label: () -> MenuLabel

    @Environment(SmartDownloads.self) private var smartDownloads
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @Environment(AppMessages.self) private var messages
    /// What keeping every unwatched episode would add, while it waits to be confirmed.
    @State private var estimate: DownloadEstimate?

    static var counts: [Int] { [3, 5, 10, 20] }

    var body: some View {
        let rule = smartDownloads.rule(for: seriesId)
        Menu {
            downloadNow()
            Section("Keep Downloaded") {
                ForEach(Self.counts, id: \.self) { count in
                    Button {
                        smartDownloads.setRule(seriesId: seriesId, seriesName: seriesName, episodesAhead: count)
                    } label: {
                        choice("Next \(count) Episodes", isChosen: rule?.episodesAhead == count)
                    }
                }
                Button {
                    Task { await estimateEveryUnwatched() }
                } label: {
                    choice("Every Unwatched Episode", isChosen: rule != nil && rule?.episodesAhead == nil)
                }
                .disabled(rule != nil && rule?.episodesAhead == nil)
            }
            if rule != nil {
                Button("Stop Smart Downloads", systemImage: "xmark", role: .destructive) {
                    smartDownloads.removeRule(seriesId: seriesId)
                }
            }
        } label: {
            label()
        }
        .confirmationDialog("Keep Every Unwatched Episode?",
                            isPresented: Binding(get: { estimate != nil }, set: { if !$0 { estimate = nil } }),
                            titleVisibility: .visible, presenting: estimate) { _ in
            Button("Keep Every Unwatched Episode") {
                smartDownloads.setRule(seriesId: seriesId, seriesName: seriesName, episodesAhead: nil)
            }
            .accessibilityIdentifier("smart.everyUnwatched.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { estimate in
            Text(message(for: estimate))
        }
    }

    @ViewBuilder private func choice(_ title: String, isChosen: Bool) -> some View {
        if isChosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func estimateEveryUnwatched() async {
        do {
            estimate = try await smartDownloads.everyUnwatchedEstimate(seriesId: seriesId)
        } catch {
            messages.show("Couldn't work out what \(seriesName) would download: \(error.localizedDescription)")
        }
    }

    private func message(for estimate: DownloadEstimate) -> String {
        let deleting = settings.deleteWatchedEpisodes ? " and each is deleted once it's watched" : ""
        let ongoing = "New episodes download as they're added to the server\(deleting)."
        guard estimate.count > 0 else {
            return "Every unwatched episode of \(seriesName) is downloaded or on its way. \(ongoing)"
        }
        let size = "\(seriesName) has \(estimate.summary(noun: "unwatched episode", plural: "unwatched episodes")) to download."
        let space = downloads.spaceForNewDownloads()
        let room = estimate.shortfall(space: space) ?? space.map { "\(DownloadEstimate.text(max(0, $0))) is free for downloads." }
        return [size, room, ongoing].compactMap(\.self).joined(separator: " ")
    }
}
#endif
