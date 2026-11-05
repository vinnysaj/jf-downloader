#if !os(tvOS)
import SwiftUI

/// Picks a version for each selected episode, says how much space the versions picked take by
/// the server's sizes, then queues them all.
/// Each episode starts on what the download settings pick (`DownloadPlanner`): the version
/// closest to the download quality, or a transcode to it when none fits and Transcode When No
/// Version Fits is on. Choosing a version for one episode can carry the same release over to
/// the rest.
struct BatchDownloadSheet: View {
    let episodes: [JellyfinItem]
    let onQueued: () -> Void

    @Environment(\.session) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var details: [String: Result<JellyfinItem, LoadFailure>] = [:]
    @State private var plans: [String: DownloadPlan] = [:]
    /// Why the account may not download what was picked.
    @State private var refusal: String?

    struct LoadFailure: Error {
        let message: String
    }

    private static let parallelLoads = 4

    private var ready: [(JellyfinItem, DownloadPlan)] {
        episodes.compactMap { episode in
            guard case .success(let detail) = details[episode.id], let plan = plans[episode.id] else { return nil }
            return (detail, plan)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !episodes.isEmpty { space }
                ForEach(episodes) { episode in
                    row(for: episode)
                }
            }
            .overlay {
                if episodes.isEmpty {
                    ContentUnavailableView("Nothing Left to Download", systemImage: "checkmark.circle",
                                           description: Text("Every episode is downloaded or on its way."))
                }
            }
            .navigationTitle(episodes.count == 1 ? "Download Episode" : episodes.isEmpty ? "Download" : "Download \(episodes.count) Episodes")
            .inlineNavigationTitle()
            .navigationDestination(for: String.self) { episodeId in
                if case .success(let detail) = details[episodeId] {
                    VersionChoiceList(
                        episode: detail,
                        transcode: transcode(of: detail),
                        selection: Binding(get: { plans[episodeId] }, set: { plans[episodeId] = $0 }),
                        applyToAll: { plan in matchAll(to: plan, from: episodeId) }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download \(ready.count)", systemImage: "arrow.down.circle") {
                        Task { await queue() }
                    }
                    .disabled(ready.isEmpty)
                    .accessibilityIdentifier("batch.download")
                }
            }
            .alert("Can't Download", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
            .task { await loadAll() }
        }
    }

    /// The space the versions picked take, against what's free, as their sizes come in.
    private var space: some View {
        let estimate = DownloadEstimate(ready.map(\.1))
        let free = downloads.spaceForNewDownloads()
        let loading = episodes.count { details[$0.id] == nil }
        return Section {
            LabeledContent("Size", value: estimate.summary(noun: "episode", plural: "episodes"))
                .accessibilityIdentifier("batch.size")
            if let free {
                LabeledContent("Free for Downloads", value: DownloadEstimate.text(max(0, free)))
            }
            if let shortfall = estimate.shortfall(space: free) {
                Label(shortfall, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } footer: {
            Text(loading > 0
                 ? "Finding the versions of \(loading) more \(loading == 1 ? "episode" : "episodes")…"
                 : estimate.transcodeCount > 0
                    ? "Sizes are the server's for versions, and estimates for transcodes, which take longer: the server works through each title as it downloads."
                    : "Sizes are the server's, for the versions picked.")
        }
    }

    @ViewBuilder private func row(for episode: JellyfinItem) -> some View {
        let title = [episode.episodeCode, episode.name].compactMap(\.self).joined(separator: " · ")
        switch details[episode.id] {
        case nil:
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text(title)
                    Text("Finding versions…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
            }
        case .failure(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Try Again", systemImage: "arrow.clockwise") {
                    details[episode.id] = nil
                    Task { await load(episode) }
                }
                .font(.caption)
            }
        case .success(let detail):
            let sources = detail.mediaSources ?? []
            NavigationLink(value: episode.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    if let plan = plans[episode.id], plan.transcode != nil {
                        Label(plan.summary, systemImage: "server.rack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let plan = plans[episode.id] {
                        VersionSummary(source: plan.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No versions").font(.caption).foregroundStyle(.red)
                    }
                    if sources.count > 1 {
                        Text("\(sources.count) versions").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(sources.isEmpty)
        }
    }

    private func loadAll() async {
        await withTaskGroup { group in
            var pending = episodes.filter { details[$0.id] == nil }.makeIterator()
            for _ in 0..<Self.parallelLoads {
                guard let episode = pending.next() else { break }
                group.addTask { await load(episode) }
            }
            while await group.next() != nil {
                if let episode = pending.next() { group.addTask { await load(episode) } }
            }
        }
    }

    private func load(_ episode: JellyfinItem) async {
        guard let session else { return }
        do {
            let detail = try await session.client.item(id: episode.id, userId: session.userId)
            details[episode.id] = .success(detail)
            if plans[episode.id] == nil {
                plans[episode.id] = DownloadPlanner.plan(for: detail, settings: settings)
            }
        } catch {
            details[episode.id] = .failure(LoadFailure(message: error.localizedDescription))
        }
    }

    /// The transcode the download settings would make of an episode, offered beside its versions.
    private func transcode(of episode: JellyfinItem) -> DownloadPlan? {
        let plan = DownloadPlanner.plan(for: episode, settings: settings)
        return plan?.transcode != nil ? plan : nil
    }

    /// The same release for every other episode, or for a transcode, what the download settings
    /// pick for each: their own transcodes where none of their versions fits.
    private func matchAll(to plan: DownloadPlan, from episodeId: String) {
        for episode in episodes where episode.id != episodeId {
            guard case .success(let detail) = details[episode.id] else { continue }
            if plan.transcode != nil {
                plans[episode.id] = DownloadPlanner.plan(for: detail, settings: settings)
            } else if let match = plan.source.closestMatch(in: detail.mediaSources ?? []) {
                plans[episode.id] = .original(match)
            }
        }
    }

    /// Queues what was picked once the account may have it, saying why not when it may not.
    private func queue() async {
        let picked = ready
        let kinds = [picked.first { $0.1.transcode == nil }, picked.first { $0.1.transcode != nil }].compactMap(\.self)
        for (_, plan) in kinds {
            if let reason = await downloads.transcodes.refusal(for: plan) {
                refusal = reason
                return
            }
        }
        for (episode, plan) in picked { downloads.enqueue(episode, plan: plan, startedByUser: true) }
        onQueued()
        dismiss()
    }
}

private struct VersionChoiceList: View {
    let episode: JellyfinItem
    /// What the download settings would transcode, when no version fits.
    let transcode: DownloadPlan?
    @Binding var selection: DownloadPlan?
    let applyToAll: (DownloadPlan) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VersionPicker(sources: episode.mediaSources ?? [], selection: Binding(
                    get: { selection?.transcode == nil ? selection?.source.id : nil },
                    set: { id in selection = episode.mediaSources?.first { $0.id == id }.map(DownloadPlan.original) }
                ))
            }
            if let transcode {
                Section {
                    Button {
                        selection = transcode
                    } label: {
                        HStack(spacing: 8) {
                            Label(transcode.summary, systemImage: "server.rack")
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                                .opacity(selection?.transcode != nil ? 1 : 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.artwork)
                    .accessibilityAddTraits(selection?.transcode != nil ? .isSelected : [])
                    .accessibilityIdentifier("version.transcode")
                } footer: {
                    Text("Every version is bigger than the download quality. The server can make one at it, which takes longer: it works through the whole title as it downloads.")
                }
            }
            Section {
                Button("Use the Closest Version for Every Episode", systemImage: "rectangle.stack") {
                    if let selection {
                        applyToAll(selection)
                        dismiss()
                    }
                }
                .disabled(selection == nil)
            } footer: {
                Text("Picks, in each other episode, the version whose name and quality share the most with this one.")
            }
        }
        .navigationTitle(episode.episodeCode ?? episode.name)
    }
}
#endif
