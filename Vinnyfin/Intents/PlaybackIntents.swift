import AppIntents
import Foundation

// Playing needs the app in front. Each play intent starts in the background, where it works out
// what to play and Siri can say why there's nothing, then brings the app forward and hands the
// title to the root view as a vinnyfin://play link, which plays it the way the app's own Play
// buttons do: the version played last, from where it got to.

/// Plays a movie from where it was left.
struct PlayMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Movie"
    static let description = IntentDescription("Plays a movie from where you left it, in the version you played last.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Movie")
    var movie: MovieEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$movie)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try ServerTitles.session(accounts)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, movie.item))
        return .result()
    }
}

/// Plays an episode from where it was left.
struct PlayEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Episode"
    static let description = IntentDescription("Plays an episode from where you left it.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$episode)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try ServerTitles.session(accounts)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, episode.item))
        return .result()
    }
}

/// Picks a show up where it was left, as its page's Play button does.
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Plays the episode of a show you're partway through from where you left it, or else the next one to watch.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Continue watching \(\.$show)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try ServerTitles.session(accounts)
        let episode = try await ShowEpisodes.upNext(of: show, session: session)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, episode))
        return .result()
    }
}

/// Moves on to a show's next episode.
struct PlayNextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Next Episode"
    static let description = IntentDescription("Plays the episode after the one you're partway through, or the next one to watch when you're not partway through one.")
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Show")
    var show: ShowEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play the next episode of \(\.$show)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try ServerTitles.session(accounts)
        let upNext = try await ShowEpisodes.upNext(of: show, session: session)
        let episode = try await ShowEpisodes.next(after: upNext, of: show, session: session)
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, episode))
        return .result()
    }
}

/// The system's way to play a video by what someone calls it: "Play Severance in vinnyfin".
/// A movie plays from where it was left, a show from the episode it's up to.
struct PlayVideoByNameIntent: PlayVideoIntent {
    static let title: LocalizedStringResource = "Play by Name"
    static let description = IntentDescription("Finds a movie or show on your server by name and plays it: a movie from where you left it, a show from the episode you're up to.")
    static let supportedCategories: [VideoCategory] = [.movies, .tv]
    static let supportedModes: IntentModes = .foreground(.deferred)

    @Parameter(title: "Name")
    var term: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$term)")
    }

    @Dependency private var accounts: AccountStore
    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = try ServerTitles.session(accounts)
        let found = try await ServerTitles.search(term, types: ["Movie", "Series"], session: session)
        guard let title = TitleMatch.best(for: term, among: found) else { throw TitleIntentError.notFound(term) }
        let item = title.isSeries
            ? try await ShowEpisodes.upNext(of: ShowEntity(title, session: session), session: session)
            : title
        try await continueInForeground(alwaysConfirm: false)
        links.open(AppLink(.play, item))
        return .result()
    }
}

// Spotlight opens a result through the open intent whose target is the result's entity type, so
// each type has one.

#if !os(tvOS)
@AppIntent(schema: .system.open)
#endif
struct OpenMovieIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Movie"
    static let description = IntentDescription("Shows a movie's page.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Movie")
    var target: MovieEntity

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.open(AppLink(.open, target.item))
        return .result()
    }
}

#if !os(tvOS)
@AppIntent(schema: .system.open)
#endif
struct OpenShowIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Show"
    static let description = IntentDescription("Shows a show's page, with its seasons and episodes.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Show")
    var target: ShowEntity

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.open(AppLink(.open, target.item))
        return .result()
    }
}

#if !os(tvOS)
@AppIntent(schema: .system.open)
#endif
struct OpenEpisodeIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Episode"
    static let description = IntentDescription("Shows an episode's page.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Episode")
    var target: EpisodeEntity

    @Dependency private var links: IncomingLinks

    @MainActor
    func perform() async throws -> some IntentResult {
        links.open(AppLink(.open, target.item))
        return .result()
    }
}

/// Which of a show's episodes the playback intents play.
enum ShowEpisodes {
    /// The episode partway through and played last, else the next one to watch: what the show's
    /// page offers to play.
    static func upNext(of show: ShowEntity, session: ServerSession) async throws -> JellyfinItem {
        let page = try await session.client.nextUp(userId: session.userId, seriesId: show.id, limit: 1)
        guard let episode = page.items.first else { throw TitleIntentError.caughtUp(show.name) }
        return episode
    }

    /// The episode to move on to from `upNext`: the one after it when it's partway through, else
    /// `upNext` itself, which nothing of has been watched.
    static func next(after upNext: JellyfinItem, of show: ShowEntity, session: ServerSession) async throws -> JellyfinItem {
        guard isPartway(upNext) else { return upNext }
        guard let next = try await session.client.episode(after: upNext.id, seriesId: show.id, userId: session.userId) else {
            throw TitleIntentError.nothingAfter(show: show.name, episode: upNext.episodeCode ?? upNext.name)
        }
        return next
    }

    nonisolated static func isPartway(_ episode: JellyfinItem) -> Bool {
        episode.resumeSeconds != nil
    }
}

/// Picks the title someone named from the server's search results.
nonisolated enum TitleMatch {
    /// The title named exactly, ignoring case and accents, with or without its year; else the
    /// shortest name that contains what was said; else the server's first.
    static func best(for term: String, among titles: [JellyfinItem]) -> JellyfinItem? {
        let said = normalized(term)
        if let exact = titles.first(where: { normalized($0.name) == said || normalized($0.titleWithYear) == said }) {
            return exact
        }
        let containing = titles.filter { normalized($0.name).contains(said) }
        return containing.min { $0.name.count < $1.name.count } ?? titles.first
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

/// Why a playback intent has nothing to play, for Siri to say.
nonisolated enum TitleIntentError: LocalizedError {
    /// Nothing comes after the last episode watched, which is how Jellyfin finds the next one.
    case caughtUp(String)
    case nothingAfter(show: String, episode: String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .caughtUp(let show): "You're caught up on \(show): there's no episode after the last one you watched."
        case .nothingAfter(let show, let episode): "\(show) has no episode after \(episode)."
        case .notFound(let term): "There's nothing called \(term) on your server."
        }
    }
}
