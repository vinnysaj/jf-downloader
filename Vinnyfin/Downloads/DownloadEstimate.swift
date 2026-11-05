#if !os(tvOS)
import Foundation

/// The space a batch of downloads takes, by the sizes the server lists for the versions chosen
/// and the bitrates transcodes are asked for, said before it starts.
nonisolated struct DownloadEstimate: Equatable, Sendable {
    /// Downloads with a version to download.
    var count = 0
    /// The listed sizes and the transcodes' estimates added up.
    var bytes: Int64 = 0
    /// Versions without a believable listed size, such as Gelato's streams, whose size is known
    /// only once the server answers for the file.
    var unknownCount = 0
    /// Transcodes, whose size is known only once they're made.
    var transcodeCount = 0

    /// One entry per download; nil for one without a version to download, which isn't counted.
    init(_ plans: [DownloadPlan?]) {
        for plan in plans.compactMap(\.self) {
            count += 1
            if plan.transcode != nil { transcodeCount += 1 }
            if let size = plan.expectedBytes { bytes += size } else { unknownCount += 1 }
        }
    }

    /// Whether it fits in `space`; it does when the space isn't known.
    func fits(in space: Int64?) -> Bool {
        space.map { bytes <= $0 } ?? true
    }

    /// "12 episodes, 18.4 GB", "12 episodes, about 9.6 GB" with transcodes, or "12 episodes, at
    /// least 4.1 GB: 3 sizes aren't listed".
    func summary(noun: String, plural: String) -> String {
        let things = "\(count) \(count == 1 ? noun : plural)"
        guard count > 0 else { return "No \(plural)" }
        guard unknownCount > 0 else { return "\(things), \(transcodeCount > 0 ? "about " : "")\(Self.text(bytes))" }
        if unknownCount == count { return "\(things), sizes not listed" }
        let unlisted = unknownCount == 1 ? "1 size isn't listed" : "\(unknownCount) sizes aren't listed"
        return "\(things), at least \(Self.text(bytes)): \(unlisted)"
    }

    /// A warning when `space` is less than this needs.
    func shortfall(space: Int64?) -> String? {
        guard let space, !fits(in: space) else { return nil }
        return "Only \(Self.text(max(0, space))) is free for downloads. The ones that don't fit stop with a message."
    }

    static func text(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
#endif
