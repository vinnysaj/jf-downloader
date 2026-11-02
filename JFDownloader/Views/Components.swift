import SwiftUI

/// A Jellyfin image at a fixed aspect ratio, filled and clipped.
struct Artwork: View {
    let url: URL?
    var aspectRatio: CGFloat = 2.0 / 3.0
    var cornerRadius: CGFloat = 6

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }
}

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

/// The versions of a title as a list of rows, one of them chosen.
struct VersionPicker: View {
    let sources: [MediaSource]
    @Binding var selection: String?

    var body: some View {
        Picker("Version", selection: $selection) {
            ForEach(sources) { source in
                VersionSummary(source: source)
                    .tag(Optional(source.id))
                    .accessibilityIdentifier("version.\(source.name ?? source.id)")
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
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

extension JellyfinItem {
    var metadataLine: String {
        var parts: [String] = []
        if isSeries { parts.append("Series") } else if type == "Movie" { parts.append("Movie") }
        if let productionYear { parts.append(String(productionYear)) }
        if let runtime { parts.append(runtime.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) }
        return parts.joined(separator: " · ")
    }
}

/// How a job is doing, in words, with the controls that apply to it.
struct JobStatusLine: View {
    @Environment(DownloadManager.self) private var downloads
    let job: DownloadJob

    var body: some View {
        switch job.status {
        case .active:
            if !downloads.isNetworkReachable {
                Label("Waiting for a network connection", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            } else if let retryAt = job.retryAt, retryAt > .now {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retrying \(Text(retryAt, style: .relative))")
                    if let lastError = job.lastError { Text(lastError).foregroundStyle(.secondary) }
                }
                .foregroundStyle(.orange)
            } else if let speed = downloads.bytesPerSecond[job.id], speed >= 1024 {
                Text("\(Int64(speed).formatted(.byteCount(style: .file)))/s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Waiting for the server…").foregroundStyle(.secondary)
            }
        case .paused:
            Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed:
            Label(job.lastError ?? "Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .completed:
            Label("Saved to \(FinishedFiles.place)", systemImage: "checkmark.circle.fill")
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
