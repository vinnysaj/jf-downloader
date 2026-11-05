import SwiftUI

/// One version of an item: its name and what's in it.
struct VersionSummary: View {
    let source: MediaSource

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(source.name ?? "Default")
                .font(.body)
                .lineLimit(4)
            let details = source.detailLine
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// The versions of a title as rows, the chosen one checked. Rows of a List inside one, a stack
/// of rows elsewhere.
struct VersionPicker: View {
    let sources: [MediaSource]
    @Binding var selection: String?

    var body: some View {
        ForEach(sources) { source in
            let isSelected = selection == source.id
            Button {
                selection = source.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VersionSummary(source: source)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.artwork)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("version.\(source.name ?? source.id)")
        }
    }
}

extension MediaSource {
    /// "1080p H264 SDR · AAC 5.1 +1 · 4.2 GB · MKV"
    var detailLine: String {
        var parts: [String] = []
        if let video = videoStream?.displayTitle { parts.append(video) }
        if let audio = audioStreams.first?.displayTitle {
            parts.append(audioStreams.count > 1 ? "\(audio) +\(audioStreams.count - 1)" : audio)
        }
        if !subtitleStreams.isEmpty { parts.append("\(subtitleStreams.count) subtitles") }
        if let size = plausibleSize { parts.append(size.formatted(.byteCount(style: .file))) }
        if let ext = fileExtension { parts.append(ext.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// Words of the name and video description, for matching versions across episodes.
    var matchTokens: Set<String> {
        let text = [name, videoStream?.displayTitle, container].compactMap(\.self).joined(separator: " ").lowercased()
        return Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The version in `candidates` most like this one (by shared words), for picking the same
    /// release across episodes. Nil when nothing shares a word.
    func closestMatch(in candidates: [MediaSource]) -> MediaSource? {
        let tokens = matchTokens
        let scored = candidates.map { candidate -> (MediaSource, Double) in
            let other = candidate.matchTokens
            let union = tokens.union(other).count
            return (candidate, union == 0 ? 0 : Double(tokens.intersection(other).count) / Double(union))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}

#if !os(tvOS)
/// What a download's status line says. While bytes arrive, that comes first, with what the
/// download waits for once its transfers under way finish, if it waits.
enum JobStatus: Equatable {
    case arriving(bytesPerSecond: Int64, next: String?)
    /// What a transcoded download's server is doing (`TranscodedDownloads.note`), with how fast
    /// its pieces arrive while they do.
    case transcoding(String, bytesPerSecond: Int64?, next: String?)
    case pausing(bytesPerSecond: Int64)
    case heldForPlayback
    case waiting(DownloadWait)
    case offline
    /// Waiting out a retry, or trying again; `othersGoFirst` while it yields.
    case retrying(at: Date?, error: String?, othersGoFirst: Bool)
    case queued
    /// In hand, it waits for another file's transfers under way to finish first.
    case startingAfter(String)
    case waitingForServer
    case paused
    case failed(String)
    case downloaded

    /// `bytesPerSecond` is how fast the job's bytes arrive, smoothed, which counts only while
    /// `isTransferring` (it has transfers under way); `transcodeNote` what its server is doing,
    /// for a transcode; `fileInHand` the job the session works on, and `waitsOn` the files whose
    /// transfers under way it waits for.
    static func of(_ job: DownloadJob, bytesPerSecond: Double?, isTransferring: Bool, transcodeNote: String? = nil,
                   waits: [UUID: DownloadWait], isPausedForPlayback: Bool, isNetworkReachable: Bool, fileInHand: UUID?,
                   waitsOn: [DownloadJob], now: Date) -> JobStatus {
        let speed = isTransferring && (bytesPerSecond ?? 0) >= 1024 ? Int64(bytesPerSecond ?? 0) : nil
        switch job.status {
        case .active:
            if let speed {
                let next = waits[job.id]?.next ?? (fileInHand != job.id && !job.yields ? "then queued" : nil)
                if let transcodeNote { return .transcoding(transcodeNote, bytesPerSecond: speed, next: next) }
                return .arriving(bytesPerSecond: speed, next: next)
            }
            if isPausedForPlayback { return .heldForPlayback }
            if let wait = waits[job.id] { return .waiting(wait) }
            if !isNetworkReachable { return .offline }
            let retryAt = job.retryAt.flatMap { $0 > now ? $0 : nil }
            if job.isFailing || retryAt != nil { return .retrying(at: retryAt, error: job.lastError, othersGoFirst: job.yields) }
            if let transcodeNote { return .transcoding(transcodeNote, bytesPerSecond: nil, next: nil) }
            if fileInHand != job.id { return .queued }
            if let overtaken = waitsOn.first { return .startingAfter(overtaken.shortName) }
            return .waitingForServer
        case .paused:
            return speed.map { .pausing(bytesPerSecond: $0) } ?? .paused
        case .failed:
            return .failed(job.lastError ?? "Failed")
        case .completed:
            return .downloaded
        }
    }
}

/// How a job is doing, in words, with the controls that apply to it. Looked at again as its
/// retry comes due, and a second later, as the countdown to it ends then: an update can come a
/// moment early, and a schedule's first update gives its first date, not the time.
struct JobStatusLine: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        TimelineView(.explicit(job.retryAt.map { [$0, $0.addingTimeInterval(1)] } ?? [])) { _ in
            line(JobStatus.of(job, bytesPerSecond: downloads.bytesPerSecond[job.id],
                              isTransferring: downloads.transferringJobIds.contains(job.id),
                              transcodeNote: downloads.transcodes.note(for: job), waits: downloads.waits,
                              isPausedForPlayback: downloads.isPausedForPlayback, isNetworkReachable: downloads.isNetworkReachable,
                              fileInHand: downloads.downloadingJobId,
                              waitsOn: downloads.jobs.filter { downloads.fileInHandWaitsOn.contains($0.id) }, now: .now))
        }
    }

    @ViewBuilder private func line(_ status: JobStatus) -> some View {
        switch status {
        case .arriving(let speed, let next):
            Text([Self.speed(speed), next].compactMap(\.self).joined(separator: " · "))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .transcoding(let note, let speed, let next):
            Label([note, speed.map(Self.speed), next].compactMap(\.self).joined(separator: " · "), systemImage: "server.rack")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("job.transcodeNote")
        case .pausing(let speed):
            Label("Pausing once the parts under way finish · \(Self.speed(speed))", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .heldForPlayback:
            Label("Paused while you watch", systemImage: "play.rectangle")
                .foregroundStyle(.secondary)
        case .waiting(let wait):
            Label(wait.status, systemImage: wait.systemImage)
                .foregroundStyle(.orange)
        case .offline:
            Label("Waiting for a network connection", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        case .retrying(let retryAt, let error, let othersGoFirst):
            VStack(alignment: .leading, spacing: 2) {
                if let retryAt {
                    Text("Retrying \(Text(retryAt, style: .relative))")
                } else {
                    Text("Trying again")
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if othersGoFirst { Text("The downloads after it go first meanwhile.").foregroundStyle(.secondary) }
            }
            .foregroundStyle(.orange)
        case .queued:
            Label("Queued", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .startingAfter(let title):
            Label("Starting once \(title) finishes the parts under way", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .waitingForServer:
            Text("Waiting for the server…").foregroundStyle(.secondary)
        case .paused:
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private static func speed(_ bytesPerSecond: Int64) -> String {
        "\(bytesPerSecond.formatted(.byteCount(style: .file)))/s"
    }
}

struct JobProgress: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        let received = downloads.receivedBytes[job.id] ?? job.bytesOnDisk
        let total = job.displayTotalBytes
        VStack(alignment: .leading, spacing: 4) {
            if let total, total > 0 {
                // A transcode's size is an estimate until it's all here.
                let about = job.transcode != nil && job.totalBytes == nil ? "about " : ""
                ProgressView(value: Double(min(received, total)), total: Double(total))
                Text("\(received.formatted(.byteCount(style: .file))) of \(about)\(total.formatted(.byteCount(style: .file)))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                // The size is known once the server answers the first request.
                ProgressView(value: 0)
                Text(received.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
#endif
