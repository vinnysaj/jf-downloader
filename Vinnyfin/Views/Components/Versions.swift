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
/// How a job is doing, in words, with the controls that apply to it.
struct JobStatusLine: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        switch job.status {
        case .active:
            if downloads.isPausedForPlayback {
                Label("Paused while you watch", systemImage: "play.rectangle")
                    .foregroundStyle(.secondary)
            } else if !downloads.isNetworkReachable {
                Label("Waiting for a network connection", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            } else if let retryAt = job.retryAt, retryAt > .now {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retrying \(Text(retryAt, style: .relative))")
                    if let lastError = job.lastError { Text(lastError).foregroundStyle(.secondary) }
                }
                .foregroundStyle(.orange)
            } else if let speed = downloads.bytesPerSecond[job.id], speed >= 1024 {
                // The next file can start as the one before it finishes its last chunks.
                Text("\(Int64(speed).formatted(.byteCount(style: .file)))/s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if downloads.downloadingJobId != job.id {
                Label("Queued", systemImage: "clock")
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for the server…").foregroundStyle(.secondary)
            }
        case .paused:
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed:
            Label(job.lastError ?? "Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .completed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

struct JobProgress: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        let received = downloads.receivedBytes[job.id] ?? job.completed.byteCount
        let total = job.displayTotalBytes
        VStack(alignment: .leading, spacing: 4) {
            if let total, total > 0 {
                ProgressView(value: Double(min(received, total)), total: Double(total))
                Text("\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
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
