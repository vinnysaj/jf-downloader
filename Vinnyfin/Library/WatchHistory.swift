import Foundation
import Observation

/// Where playback got to, kept on this device: for local files, which the server knows nothing
/// about, and for server items played while the server couldn't be reached, until it can be
/// told. Server items played online are the server's to remember; they are kept here too so
/// downloaded items show their progress offline.
@Observable
final class WatchHistory {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var position: Double
        var duration: Double?
        var played: Bool
        var updatedAt: Date
        /// The server hasn't been told yet. Only for server items.
        var needsSync: Bool
    }

    /// Positions this close to the start or end count as not started and as watched, matching
    /// Jellyfin's defaults (5% and 90%).
    nonisolated static let minimumResumeFraction = 0.05
    nonisolated static let playedFraction = 0.9

    private(set) var entries: [String: Entry] = [:]
    /// Why the history couldn't be loaded or saved, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let file: URL

    init(file: URL = URL.applicationSupportDirectory.appending(path: "WatchHistory.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
        } catch {
            problem = "Couldn't read the watch history: \(error.localizedDescription)"
        }
    }

    /// The key for a file on this device, stable across renames within a folder and moves:
    /// its name and size.
    nonisolated static func fileKey(name: String, size: Int64) -> String {
        "file:\(name):\(size)"
    }

    func entry(for key: String) -> Entry? { entries[key] }

    /// Seconds to resume from, or nil to start at the beginning.
    func resumePosition(for key: String) -> Double? {
        guard let entry = entries[key], !entry.played, entry.position > 0 else { return nil }
        return entry.position
    }

    func record(key: String, position: Double, duration: Double?, needsSync: Bool, now: Date = .now) {
        let played = Self.isPlayed(position: position, duration: duration)
        let kept = played ? 0 : Self.isStarted(position: position, duration: duration) ? position : 0
        // A report the server took supersedes anything still queued for it.
        entries[key] = Entry(position: kept, duration: duration, played: played, updatedAt: now, needsSync: needsSync)
        save()
    }

    func markPlayed(_ played: Bool, key: String, needsSync: Bool, now: Date = .now) {
        var entry = entries[key] ?? Entry(position: 0, duration: nil, played: played, updatedAt: now, needsSync: needsSync)
        entry.played = played
        entry.position = 0
        entry.updatedAt = now
        entry.needsSync = needsSync
        entries[key] = entry
        save()
    }

    /// Sends what was watched offline to the server. Entries stay queued while it can't be
    /// reached; one it refuses outright (the item is gone from the library) is dropped and said so.
    func syncPending(using client: JellyfinClient, userId: String) async {
        var refused: [String] = []
        for (key, entry) in entries where entry.needsSync && !key.hasPrefix("file:") {
            do {
                try await client.updateUserData(
                    itemId: key, userId: userId,
                    positionTicks: Int64(entry.position * 10_000_000), played: entry.played, lastPlayed: entry.updatedAt
                )
                entries[key]?.needsSync = false
            } catch JellyfinError.http(let status, let body) where (400..<500).contains(status) && status != 401 && status != 408 && status != 429 {
                entries[key]?.needsSync = false
                refused.append(body.isEmpty ? "HTTP \(status)" : body)
            } catch {
                // Offline or the server is down; the next sync tries again.
                continue
            }
        }
        if !refused.isEmpty {
            problem = "The server didn't take what was watched offline for \(refused.count) item(s): \(refused[0])"
        }
        save()
    }

    var hasPendingSync: Bool { entries.contains { !$0.key.hasPrefix("file:") && $0.value.needsSync } }

    nonisolated static func isPlayed(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position / duration >= playedFraction
    }

    nonisolated static func isStarted(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return position > 30 }
        return position / duration >= minimumResumeFraction
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch {
            problem = "Couldn't save the watch history: \(error.localizedDescription)"
        }
    }
}
