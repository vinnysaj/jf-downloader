import Foundation

/// A picture size someone wants: for streaming, and separately for downloads.
nonisolated enum VideoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Whatever the best version is, untouched.
    case original
    case uhd = "2160p"
    case fullHD = "1080p"
    case hd = "720p"
    case sd = "480p"

    var id: Self { self }

    var label: String {
        switch self {
        case .original: "Best Available"
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        case .sd: "480p"
        }
    }

    /// Nil when there is no limit.
    var maxHeight: Int? {
        switch self {
        case .original: nil
        case .uhd: 2160
        case .fullHD: 1080
        case .hd: 720
        case .sd: 480
        }
    }

    /// The bitrate a transcode to this size is asked for.
    var transcodeBitrate: Int {
        switch self {
        case .original: 120_000_000
        case .uhd: 60_000_000
        case .fullHD: 16_000_000
        case .hd: 6_000_000
        case .sd: 2_500_000
        }
    }
}

/// What a version of a title is, as far as picking one goes.
nonisolated struct VersionTraits: Equatable, Sendable {
    /// The picture's class in lines: 2160, 1080, 720 and so on. Nil when nothing says.
    let resolutionClass: Int?

    init(_ source: MediaSource) {
        resolutionClass = Self.resolutionClass(of: source)
    }

    /// From the video stream's size, treating a wide 1920x800 as 1080p; failing that, from
    /// the version's name ("4K HDR", "1080p WEB-DL"), which is all a Gelato stream has
    /// before it is first opened.
    static func resolutionClass(of source: MediaSource) -> Int? {
        if let video = source.videoStream, let width = video.width, let height = video.height, width > 0, height > 0 {
            return snap(max(height, width * 9 / 16))
        }
        let text = [source.name, source.videoStream?.displayTitle].compactMap(\.self).joined(separator: " ").lowercased()
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !tokens.isDisjoint(with: ["2160p", "4k", "uhd", "2160"]) { return 2160 }
        if !tokens.isDisjoint(with: ["1440p", "2k", "1440"]) { return 1440 }
        if !tokens.isDisjoint(with: ["1080p", "1080i", "fhd", "1080"]) { return 1080 }
        if !tokens.isDisjoint(with: ["720p", "720"]) { return 720 }
        if !tokens.isDisjoint(with: ["576p", "540p", "480p", "sd", "dvd", "480", "576"]) { return 480 }
        return nil
    }

    /// Rounds a measured height to the class it was mastered at, so 1036 or 1088 is 1080.
    static func snap(_ height: Int) -> Int {
        let classes = [4320, 2160, 1440, 1080, 720, 576, 480, 360, 240]
        return classes.min { abs($0 - height) < abs($1 - height) } ?? height
    }
}

/// How to get a version to the screen.
nonisolated enum PlaybackPlan: Equatable, Sendable {
    /// The original file, as it is.
    case direct(MediaSource)
    /// The server scales this version down to `quality`.
    case transcode(MediaSource, VideoQuality)
}

nonisolated enum VersionChooser {
    /// The version to play or download at `quality`: the best one that fits, in the server's
    /// order (Gelato ranks streams best first). When none fits, the smallest one that doesn't,
    /// which `planStreaming` then has the server scale down.
    static func choose(from sources: [MediaSource], quality: VideoQuality) -> MediaSource? {
        guard let cap = quality.maxHeight else { return sources.first }
        let known = sources.compactMap { source in VersionTraits(source).resolutionClass.map { (source, $0) } }
        // `max(by:)` and `min(by:)` return the first of equal elements, so ties keep the server's order.
        if let best = known.filter({ $0.1 <= cap }).max(by: { $0.1 < $1.1 }) { return best.0 }
        // Nothing known fits: an unlabelled version may, and is tried before scaling one down.
        if let unknown = sources.first(where: { VersionTraits($0).resolutionClass == nil }) { return unknown }
        return known.min(by: { $0.1 < $1.1 })?.0 ?? sources.first
    }

    /// Streaming: the chosen version as it is when it fits the quality, otherwise scaled down
    /// by the server when transcoding is allowed.
    static func planStreaming(sources: [MediaSource], preferred: MediaSource?, quality: VideoQuality, allowTranscoding: Bool) -> PlaybackPlan? {
        guard let source = preferred ?? choose(from: sources, quality: quality) else { return nil }
        guard let cap = quality.maxHeight, allowTranscoding,
              let resolution = VersionTraits(source).resolutionClass, resolution > cap
        else { return .direct(source) }
        return .transcode(source, quality)
    }
}
