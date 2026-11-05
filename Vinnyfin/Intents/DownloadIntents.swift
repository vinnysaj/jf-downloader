#if !os(tvOS)
import AppIntents
import Foundation

/// Queues a show's next episodes to watch, once, in the download quality.
struct DownloadNextEpisodesIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Next Episodes"
    static let description = IntentDescription("Downloads the next episodes to watch of a show, in the download quality, to watch offline.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Show")
    var show: ShowEntity

    @Parameter(title: "Episodes", default: 3, inclusiveRange: (1, 50))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Download the next \(\.$count) episodes of \(\.$show)")
    }

    @Dependency private var smartDownloads: SmartDownloads

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let queued = try await smartDownloads.downloadNext(count, seriesId: show.id)
        let text = IntentSummaries.queued(queued, of: show.name, asked: count)
        return .result(value: queued.count, dialog: IntentDialog("\(text)"))
    }
}

/// Queues a movie as the download settings say: its version closest to the download quality, or
/// a transcode to it when every version is bigger and Transcode When No Version Fits is on.
struct DownloadMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Movie"
    static let description = IntentDescription("Downloads a movie in the download quality, to watch offline.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Movie")
    var movie: MovieEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$movie)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var settings: AppSettings
    @Dependency private var downloads: DownloadManager

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let job = downloads.jobs(forItem: movie.id).first {
            return .result(dialog: IntentDialog("\(IntentSummaries.alreadyThere(job))"))
        }
        let session = try ServerTitles.session(accounts)
        let detail = try await session.client.item(id: movie.id, userId: session.userId)
        guard let plan = DownloadPlanner.plan(for: detail, settings: settings) else { throw PlaybackError.noVersions }
        if let refusal = await downloads.transcodes.refusal(for: plan) { throw DownloadRefused(message: refusal) }
        downloads.enqueue(detail, plan: plan, startedByUser: true)
        // Queued, or turned away at once for want of space.
        let job = downloads.jobs(forItem: movie.id).first
        let summary = IntentSummaries.movieQueued(job, name: detail.name, plan: plan,
                                                  isOneOfSeveral: (detail.mediaSources?.count ?? 0) > 1)
        return .result(dialog: IntentDialog("\(summary)"))
    }
}

struct PauseAllDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Downloads"
    static let description = IntentDescription("Pauses every download under way.")
    static let supportedModes: IntentModes = .background

    @Dependency private var downloads: DownloadManager

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = downloads.jobs.count { $0.status == .active }
        downloads.pauseAll()
        return .result(dialog: IntentDialog("\(IntentSummaries.paused(count))"))
    }
}

struct ResumeAllDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Downloads"
    static let description = IntentDescription("Resumes every paused download and retries the ones that stopped.")
    static let supportedModes: IntentModes = .background

    @Dependency private var downloads: DownloadManager

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = downloads.jobs.count { $0.status == .paused || $0.status == .failed }
        downloads.resumeAll()
        return .result(dialog: IntentDialog("\(IntentSummaries.resumed(count))"))
    }
}

/// Says what's downloading, how far along it is and what's ready to watch offline.
struct DownloadStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Downloading"
    static let description = IntentDescription("Tells you what's downloading, how far along it is, and what's ready to watch offline.")
    static let supportedModes: IntentModes = .background

    @Dependency private var downloads: DownloadManager
    @Dependency private var history: WatchHistory

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = DownloadsSnapshot(downloads, history: history).summary
        return .result(value: summary, dialog: IntentDialog("\(summary)"))
    }
}

/// What the intents say once they've acted.
nonisolated enum IntentSummaries {
    static func queued(_ episodes: [JellyfinItem], of show: String, asked: Int) -> String {
        switch episodes.count {
        case 0:
            return asked == 1
                ? "The next episode of \(show) is already downloaded or on its way."
                : "The next \(asked) episodes of \(show) are already downloaded or on their way."
        case 1:
            return "Downloading \(code(episodes[0])) of \(show)."
        default:
            let codes = episodes.map(code)
            return "Downloading \(episodes.count) episodes of \(show): \(codes.formatted(.list(type: .and)))."
        }
    }

    static func alreadyThere(_ job: DownloadJob) -> String {
        switch job.status {
        case .completed: "\(job.title) is already downloaded."
        case .active: "\(job.title) is already downloading."
        case .paused: "\(job.title) is already in your downloads, paused."
        case .failed: "\(job.title) is in your downloads but stopped: \(job.lastError ?? "it failed")"
        }
    }

    /// The version is named only when it was picked from several: a movie's only version is
    /// named after the file, which repeats the movie's name.
    static func movieQueued(_ job: DownloadJob?, name: String, plan: DownloadPlan, isOneOfSeveral: Bool) -> String {
        if let job, job.status == .failed, let error = job.lastError { return "Couldn't download \(name). \(error)" }
        let details = switch plan {
        case .original(let source):
            [isOneOfSeveral ? source.name : nil, source.plausibleSize.map(DownloadEstimate.text)].compactMap(\.self).joined(separator: ", ")
        case .transcode(_, let request):
            [request.label, request.estimatedBytes.map { "about \(DownloadEstimate.text($0))" }].compactMap(\.self).joined(separator: ", ")
        }
        return details.isEmpty ? "Downloading \(name)." : "Downloading \(name): \(details)."
    }

    static func paused(_ count: Int) -> String {
        switch count {
        case 0: "Nothing is downloading."
        case 1: "Paused 1 download."
        default: "Paused \(count) downloads."
        }
    }

    static func resumed(_ count: Int) -> String {
        switch count {
        case 0: "No downloads are paused."
        case 1: "Resumed 1 download."
        default: "Resumed \(count) downloads."
        }
    }

    private static func code(_ episode: JellyfinItem) -> String {
        episode.episodeCode ?? episode.name
    }
}
#endif
