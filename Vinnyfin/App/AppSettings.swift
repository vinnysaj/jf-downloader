import Foundation
import Observation

/// The choices in Settings, kept in UserDefaults, and in iCloud so they follow the person to all
/// their devices, apart from those in `deviceOnlyKeys`. A new setting follows them too, unless
/// it's added there.
@Observable
final class AppSettings {
    nonisolated enum SubtitleMode: String, CaseIterable, Identifiable, Sendable {
        /// Never, unless picked in the player.
        case off
        /// Only forced tracks, which translate signs and foreign dialogue.
        case forcedOnly
        /// Whenever the audio isn't in the subtitle language.
        case smart
        /// Always, in the subtitle language.
        case always

        var id: Self { self }

        var label: String {
            switch self {
            case .off: "Off"
            case .forcedOnly: "Forced Only"
            case .smart: "When the Audio Is Foreign"
            case .always: "Always"
            }
        }
    }

    nonisolated enum Appearance: String, CaseIterable, Identifiable, Sendable {
        /// Light or dark with the system.
        case system
        case light
        case dark

        var id: Self { self }

        var label: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The browsing screens' look; the player is always dark.
    var appearance = Appearance.system { didSet { store(appearance.rawValue, Keys.appearance) } }
    var streamingQuality = VideoQuality.original { didSet { store(streamingQuality.rawValue, Keys.streamingQuality) } }
    /// Lets the server scale a version down when none matches `streamingQuality`.
    var allowTranscoding = true { didSet { store(allowTranscoding, Keys.allowTranscoding) } }
    /// Moves a stream the connection can't keep up with to a smaller version, or to a transcode
    /// when `allowTranscoding` lets it, as it plays.
    var adaptiveQuality = true { didSet { store(adaptiveQuality, Keys.adaptiveQuality) } }
    var downloadQuality = VideoQuality.fullHD { didSet { store(downloadQuality.rawValue, Keys.downloadQuality) } }
    /// Has the server make a download at `downloadQuality` when every version of a title is
    /// bigger, rather than downloading the smallest as it is.
    var transcodeDownloads = false { didSet { store(transcodeDownloads, Keys.transcodeDownloads) } }
    /// Deletes a downloaded episode once it has been watched, here or on another device.
    var deleteWatchedEpisodes = true { didSet { store(deleteWatchedEpisodes, Keys.deleteWatchedEpisodes) } }
    /// How many episodes a new smart download keeps ahead.
    var smartDownloadCount = 10 { didSet { store(smartDownloadCount, Keys.smartDownloadCount) } }
    /// Lets downloads use cellular data and Personal Hotspots.
    var downloadOverCellular = false { didSet { store(downloadOverCellular, Keys.downloadOverCellular) } }
    /// Downloads wait while the device isn't plugged in.
    var downloadOnlyWhileCharging = false { didSet { store(downloadOnlyWhileCharging, Keys.downloadOnlyWhileCharging) } }
    /// Plays audio in the background while downloads go on, so the system keeps the app
    /// running (`KeepAwakeAudio`), on iPhone, iPad and Vision Pro.
    var keepDownloadsRunning = false { didSet { store(keepDownloadsRunning, Keys.keepDownloadsRunning) } }
    /// The web address of an audio file for Keep Downloads Running to loop; empty for silence.
    var keepDownloadsRunningSound = "" { didSet { store(keepDownloadsRunningSound, Keys.keepDownloadsRunningSound) } }
    /// Keep Downloads Running carries on playing once downloads finish, until the person stops it.
    var keepPlayingAfterDownloads = false { didSet { store(keepPlayingAfterDownloads, Keys.keepPlayingAfterDownloads) } }
    /// Gigabytes downloads may take up in all, one of `storageLimitChoices`; 0 for no limit.
    var downloadStorageLimit = 0 { didSet { store(downloadStorageLimit, Keys.downloadStorageLimit) } }
    /// Notifies when downloads are ready to watch offline, and when one needs attention.
    var downloadNotifications = true { didSet { store(downloadNotifications, Keys.downloadNotifications) } }
    var autoplayNextEpisode = true { didSet { store(autoplayNextEpisode, Keys.autoplayNextEpisode) } }
    /// Offers to skip intros, recaps, previews and credits the server has marked.
    var showSkipButtons = true { didSet { store(showSkipButtons, Keys.showSkipButtons) } }
    /// ISO 639-2 code, such as "eng"; empty plays the file's default track.
    var audioLanguage = "" { didSet { store(audioLanguage, Keys.audioLanguage) } }
    var subtitleLanguage = "eng" { didSet { store(subtitleLanguage, Keys.subtitleLanguage) } }
    var subtitleMode = SubtitleMode.forcedOnly { didSet { store(subtitleMode.rawValue, Keys.subtitleMode) } }
    /// Relative to the standard size.
    var subtitleScale = 1.0 { didSet { store(subtitleScale, Keys.subtitleScale) } }
    /// Switches the TV's frame rate and dynamic range to the video's (Apple TV).
    var matchContent = true { didSet { store(matchContent, Keys.matchContent) } }

    private let defaults: UserDefaults
    @ObservationIgnored private let cloud: (any CloudKeyValues)?
    /// The settings are being read from the defaults rather than chosen.
    @ObservationIgnored private var isLoading = false

    nonisolated private enum Keys {
        /// Every setting's key starts with it.
        static let prefix = "settings."
        static let appearance = "settings.appearance"
        static let streamingQuality = "settings.streamingQuality"
        static let allowTranscoding = "settings.allowTranscoding"
        static let adaptiveQuality = "settings.adaptiveQuality"
        static let downloadQuality = "settings.downloadQuality"
        static let transcodeDownloads = "settings.transcodeDownloads"
        static let deleteWatchedEpisodes = "settings.deleteWatchedEpisodes"
        static let smartDownloadCount = "settings.smartDownloadCount"
        static let downloadOverCellular = "settings.downloadOverCellular"
        static let downloadOnlyWhileCharging = "settings.downloadOnlyWhileCharging"
        static let keepDownloadsRunning = "settings.keepDownloadsRunning"
        static let keepDownloadsRunningSound = "settings.keepDownloadsRunningSound"
        static let keepPlayingAfterDownloads = "settings.keepPlayingAfterDownloads"
        static let downloadStorageLimit = "settings.downloadStorageLimit"
        static let downloadNotifications = "settings.downloadNotifications"
        static let autoplayNextEpisode = "settings.autoplayNextEpisode"
        // Named for when it only covered intros; renaming it would reset everyone's choice.
        static let showSkipButtons = "settings.showSkipIntro"
        static let audioLanguage = "settings.audioLanguage"
        static let subtitleLanguage = "settings.subtitleLanguage"
        static let subtitleMode = "settings.subtitleMode"
        static let subtitleScale = "settings.subtitleScale"
        static let matchContent = "settings.matchContent"
    }

    init(defaults: UserDefaults = .standard, cloud: (any CloudKeyValues)? = nil) {
        self.defaults = defaults
        self.cloud = cloud
        load()
    }

    /// Reads the settings from the defaults; one never chosen keeps its default.
    private func load() {
        isLoading = true
        defer { isLoading = false }
        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init) ?? appearance
        streamingQuality = defaults.string(forKey: Keys.streamingQuality).flatMap(VideoQuality.init) ?? streamingQuality
        allowTranscoding = defaults.object(forKey: Keys.allowTranscoding) as? Bool ?? allowTranscoding
        adaptiveQuality = defaults.object(forKey: Keys.adaptiveQuality) as? Bool ?? adaptiveQuality
        downloadQuality = defaults.string(forKey: Keys.downloadQuality).flatMap(VideoQuality.init) ?? downloadQuality
        transcodeDownloads = defaults.object(forKey: Keys.transcodeDownloads) as? Bool ?? transcodeDownloads
        deleteWatchedEpisodes = defaults.object(forKey: Keys.deleteWatchedEpisodes) as? Bool ?? deleteWatchedEpisodes
        smartDownloadCount = defaults.object(forKey: Keys.smartDownloadCount) as? Int ?? smartDownloadCount
        downloadOverCellular = defaults.object(forKey: Keys.downloadOverCellular) as? Bool ?? downloadOverCellular
        downloadOnlyWhileCharging = defaults.object(forKey: Keys.downloadOnlyWhileCharging) as? Bool ?? downloadOnlyWhileCharging
        keepDownloadsRunning = defaults.object(forKey: Keys.keepDownloadsRunning) as? Bool ?? keepDownloadsRunning
        keepDownloadsRunningSound = defaults.string(forKey: Keys.keepDownloadsRunningSound) ?? keepDownloadsRunningSound
        keepPlayingAfterDownloads = defaults.object(forKey: Keys.keepPlayingAfterDownloads) as? Bool ?? keepPlayingAfterDownloads
        downloadStorageLimit = defaults.object(forKey: Keys.downloadStorageLimit) as? Int ?? downloadStorageLimit
        downloadNotifications = defaults.object(forKey: Keys.downloadNotifications) as? Bool ?? downloadNotifications
        autoplayNextEpisode = defaults.object(forKey: Keys.autoplayNextEpisode) as? Bool ?? autoplayNextEpisode
        showSkipButtons = defaults.object(forKey: Keys.showSkipButtons) as? Bool ?? showSkipButtons
        audioLanguage = defaults.string(forKey: Keys.audioLanguage) ?? audioLanguage
        subtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage) ?? subtitleLanguage
        subtitleMode = defaults.string(forKey: Keys.subtitleMode).flatMap(SubtitleMode.init) ?? subtitleMode
        subtitleScale = defaults.object(forKey: Keys.subtitleScale) as? Double ?? subtitleScale
        matchContent = defaults.object(forKey: Keys.matchContent) as? Bool ?? matchContent
    }

    private func store(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        if Self.syncs(key) { cloud?.set(value, forKey: key) }
    }

    // MARK: iCloud

    /// The settings that stay on the device they're chosen on, as what suits one device doesn't
    /// suit another: the streaming quality suits its screen and its connection; the episodes smart
    /// downloads keep and the space downloads may take suit its storage, as a Mac's isn't an
    /// iPhone's; cellular data, charging and keeping downloads running in the background suit how
    /// it's carried and powered; and matching the frame rate and dynamic range suits the TV it's
    /// plugged into. The download quality, whether downloads may be transcoded to it, the sound
    /// that keeps downloads running and their notifications are the person's taste, and follow
    /// them.
    nonisolated static let deviceOnlyKeys: Set<String> = [
        Keys.streamingQuality, Keys.smartDownloadCount, Keys.downloadStorageLimit, Keys.downloadOverCellular,
        Keys.downloadOnlyWhileCharging, Keys.keepDownloadsRunning, Keys.keepPlayingAfterDownloads, Keys.matchContent,
    ]

    /// Whether the setting under `key` follows the person to their other devices.
    nonisolated static func syncs(_ key: String) -> Bool {
        key.hasPrefix(Keys.prefix) && !deviceOnlyKeys.contains(key)
    }

    /// Brings this device's settings and iCloud's together, as iCloud hands over its whole store.
    func reconcileWithCloud() {
        guard let cloud else { return }
        let merge = SettingsMerge(local: defaults.dictionaryRepresentation(), cloud: cloud.dictionaryRepresentation, syncs: Self.syncs)
        for (key, value) in merge.uploaded { cloud.set(value, forKey: key) }
        adopt(merge.adopted)
    }

    /// Takes the settings another device changed.
    func cloudChanged(_ keys: [String]) {
        guard let cloud else { return }
        var values: [String: Any] = [:]
        for key in keys where Self.syncs(key) {
            if let value = cloud.object(forKey: key) { values[key] = value }
        }
        adopt(values)
    }

    private func adopt(_ values: [String: Any]) {
        guard !values.isEmpty else { return }
        for (key, value) in values { defaults.set(value, forKey: key) }
        load()
    }

    /// The storage limits offered, in gigabytes; 0 is no limit.
    nonisolated static let storageLimitChoices = [0, 10, 25, 50, 100, 250, 500]

    /// Languages offered for audio and subtitles, by their ISO 639-2 codes.
    nonisolated static let languages: [(code: String, name: String)] = {
        let codes = ["eng", "spa", "fre", "ger", "ita", "por", "dut", "swe", "nor", "dan", "fin", "pol", "rus", "ukr",
                     "tur", "ara", "heb", "hin", "jpn", "kor", "chi", "tha", "vie", "ind", "gre", "cze", "hun", "rum"]
        return codes.map { ($0, displayName(for: $0)) }.sorted { $0.1 < $1.1 }
    }()

    nonisolated static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Jellyfin and Matroska tag languages with ISO 639-2 (B) codes.
    nonisolated static func threeLetterCode(for twoLetter: String) -> String {
        let map = ["en": "eng", "es": "spa", "fr": "fre", "de": "ger", "it": "ita", "pt": "por", "nl": "dut",
                   "sv": "swe", "nb": "nor", "no": "nor", "da": "dan", "fi": "fin", "pl": "pol", "ru": "rus",
                   "uk": "ukr", "tr": "tur", "ar": "ara", "he": "heb", "hi": "hin", "ja": "jpn", "ko": "kor",
                   "zh": "chi", "th": "tha", "vi": "vie", "id": "ind", "el": "gre", "cs": "cze", "hu": "hun", "ro": "rum"]
        return map[twoLetter] ?? twoLetter
    }

    /// Whether two language tags name the same language: "eng", "en" and "en-US" all do.
    nonisolated static func sameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        func normalized(_ tag: String) -> String {
            let base = tag.lowercased().split(separator: "-").first.map(String.init) ?? tag.lowercased()
            let aliases = ["fra": "fre", "deu": "ger", "nld": "dut", "zho": "chi", "ces": "cze", "ell": "gre", "ron": "rum"]
            let three = base.count == 2 ? threeLetterCode(for: base) : base
            return aliases[three] ?? three
        }
        return normalized(lhs) == normalized(rhs)
    }
}
