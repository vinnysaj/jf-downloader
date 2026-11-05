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

    /// The sizes with a limit, largest first.
    static let limited: [VideoQuality] = [.uhd, .fullHD, .hd, .sd]

    /// The smallest limit a picture `height` lines tall fits in.
    static func fitting(height: Int) -> VideoQuality {
        limited.last { ($0.maxHeight ?? .max) >= height } ?? .original
    }
}

/// What a version of a title is, as far as picking one goes.
nonisolated struct VersionTraits: Equatable, Sendable {
    /// The picture's class in lines: 2160, 1080, 720 and so on. Nil when nothing says.
    let resolutionClass: Int?
    /// Bits per second, as the server measured the file. Nil when it hasn't, as for a Gelato
    /// stream before it is first opened.
    let bitrate: Int?

    init(_ source: MediaSource) {
        resolutionClass = Self.resolutionClass(of: source)
        bitrate = source.bitrate.flatMap { $0 > 100_000 ? $0 : nil }
    }

    /// The bitrate, or failing that a generous guess from the picture's class: what a transcode
    /// to that size is asked for.
    var estimatedBitrate: Int? {
        bitrate ?? resolutionClass.map { VideoQuality.fitting(height: $0).transcodeBitrate }
    }

    /// "4K", "1080p": the class as the quality settings name it.
    static func label(forResolution resolution: Int) -> String {
        resolution == 2160 ? VideoQuality.uhd.label : "\(resolution)p"
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

    var source: MediaSource {
        switch self {
        case .direct(let source), .transcode(let source, _): source
        }
    }

    /// The picture size it plays at, as the quality settings name it: "4K", "720p". Nil when
    /// nothing says.
    var label: String? {
        switch self {
        case .direct(let source): VersionTraits(source).resolutionClass.map(VersionTraits.label(forResolution:))
        case .transcode(_, let quality): quality.label
        }
    }
}

nonisolated enum VersionChooser {
    /// The version to play or download at `quality`: the best one that fits, in the order of
    /// `sources`, which is the item's own version first and the rest in the server's order, as
    /// `JellyfinClient.item` lists them (Gelato ranks streams best first). When none fits, the
    /// smallest one that doesn't, which `planStreaming` then has the server scale down.
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

    /// A cheaper way to go on playing a title when the connection can't keep up with `playing`:
    /// the best version below it that the connection carries, else a transcode it carries, when
    /// transcoding is allowed. Without a measured throughput it takes one step: the next version
    /// down, else the next transcode down. When nothing fits the throughput, the cheapest there
    /// is. Nil when nothing is cheaper.
    ///
    /// - Parameters:
    ///   - bitrate: What `playing` was measured at, in bits per second, when it was.
    ///   - throughput: What the connection delivers, in bits per second, when it was measured.
    static func planStepDown(from playing: PlaybackPlan, bitrate: Int?, throughput: Int?,
                             sources: [MediaSource], allowTranscoding: Bool) -> PlaybackPlan? {
        struct Option {
            let plan: PlaybackPlan
            let bitrate: Int
            let resolution: Int?
            /// Ranks the dearest first, keeping the server's order between equals.
            let order: Int
            func isDearer(than other: Option) -> Bool {
                (bitrate, resolution ?? 0, -order) > (other.bitrate, other.resolution ?? 0, -other.order)
            }
        }
        let currentResolution: Int?
        let currentBitrate: Int?
        switch playing {
        case .direct(let source):
            currentResolution = VersionTraits(source).resolutionClass
            currentBitrate = bitrate ?? VersionTraits(source).estimatedBitrate
        case .transcode(_, let quality):
            currentResolution = quality.maxHeight
            currentBitrate = bitrate ?? quality.transcodeBitrate
        }
        guard let currentBitrate else { return nil }
        // A step has to save enough to be worth the pause it costs, and never makes the picture bigger.
        func isCheaper(bitrate: Int, resolution: Int?) -> Bool {
            if let resolution, let currentResolution, resolution > currentResolution { return false }
            return Double(bitrate) <= Double(currentBitrate) * 0.85
        }
        let versions = sources.enumerated().compactMap { index, source -> Option? in
            let traits = VersionTraits(source)
            guard let estimate = traits.estimatedBitrate, isCheaper(bitrate: estimate, resolution: traits.resolutionClass) else { return nil }
            return Option(plan: .direct(source), bitrate: estimate, resolution: traits.resolutionClass, order: index)
        }
        let transcodes = !allowTranscoding ? [] : VideoQuality.limited.enumerated().compactMap { index, quality -> Option? in
            guard isCheaper(bitrate: quality.transcodeBitrate, resolution: quality.maxHeight) else { return nil }
            let source = transcodeSource(for: quality, from: sources) ?? playing.source
            return Option(plan: .transcode(source, quality), bitrate: quality.transcodeBitrate, resolution: quality.maxHeight, order: index)
        }
        let dearestFirst = { (options: [Option]) in options.sorted { $0.isDearer(than: $1) } }
        guard let throughput else {
            return (dearestFirst(versions).first ?? dearestFirst(transcodes).first)?.plan
        }
        // Room for the connection's dips and for the audio.
        let budget = Double(throughput) * 0.8
        let fits = { (option: Option) in Double(option.bitrate) <= budget }
        if let version = dearestFirst(versions).first(where: fits) { return version.plan }
        if let transcode = dearestFirst(transcodes).first(where: fits) { return transcode.plan }
        return dearestFirst(versions + transcodes).last?.plan
    }

    /// The version a transcode to `quality` is best made from: the smallest that is at least
    /// that size, which is the least for the server to read and scale.
    private static func transcodeSource(for quality: VideoQuality, from sources: [MediaSource]) -> MediaSource? {
        let height = quality.maxHeight ?? 0
        return sources.filter { (VersionTraits($0).resolutionClass ?? 0) >= height }.min { lhs, rhs in
            let (left, right) = (VersionTraits(lhs), VersionTraits(rhs))
            return (left.resolutionClass ?? 0, left.estimatedBitrate ?? .max) < (right.resolutionClass ?? 0, right.estimatedBitrate ?? .max)
        }
    }
}
