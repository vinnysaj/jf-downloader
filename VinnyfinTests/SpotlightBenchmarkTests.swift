#if !os(tvOS)
import Darwin
import Foundation
import Testing
@testable import vinnyfin

nonisolated private let benchmarkMode = ProcessInfo.processInfo.environment["VINNYFIN_SPOTLIGHT_BENCHMARK"]

/// What a library of 20,000 titles costs in Spotlight, which `SpotlightPlan.limit` is set from:
/// building the entries, their fingerprints and the ledger for all of them, and writing the first
/// `SpotlightPlan.limit` to the app's index, as a pass at most does. Off unless
/// `VINNYFIN_SPOTLIGHT_BENCHMARK` is set (as `TEST_RUNNER_VINNYFIN_SPOTLIGHT_BENCHMARK` for
/// xcodebuild): `write` leaves the entries in, to measure the index on disk, and `delete` takes
/// them out again by their ids. Spotlight's own work on the writes, after they return, shows in
/// its log: each "Completed donation" of `add-update-items`.
@Suite(.enabled(if: benchmarkMode != nil), .serialized)
struct SpotlightBenchmarkTests {
    private static let count = 20_000
    private let session = ServerSession(
        client: JellyfinClient(serverURL: URL(string: "http://192.168.1.20:8096")!, deviceId: "d", deviceName: "iPhone", token: "tok"),
        account: AccountStore.Account(serverURL: URL(string: "http://192.168.1.20:8096")!, serverId: "server", userId: "u", userName: "Alex")
    )

    @Test func writesAPassOfTwentyThousandTitles() async throws {
        guard benchmarkMode == "write" else { return }
        let clock = ContinuousClock()
        let memoryBefore = Self.footprint()

        var entries: [SpotlightEntry] = []
        let built = clock.measure {
            entries = (0..<Self.count).compactMap { SpotlightEntry(Self.item($0), priority: 0, session: session) }
        }
        var fingerprints: [SpotlightEntity.Kind: [String: String]] = [:]
        let fingerprinted = clock.measure {
            fingerprints = SpotlightLedger.byKind(entries.map { ($0.entity.kind, $0.entity.id, $0.fingerprint) })
        }
        var ledger = SpotlightLedger(account: SpotlightLedger.AccountKey(session.account))
        ledger.fingerprints = fingerprints
        var ledgerData = Data()
        let encoded = try clock.measure { ledgerData = try JSONEncoder().encode(ledger) }
        let decoded = try clock.measure { _ = try JSONDecoder().decode(SpotlightLedger.self, from: ledgerData) }
        let unchanged = clock.measure { _ = SpotlightLedger.Changes(from: fingerprints, to: fingerprints) }

        print("""
            SPOTLIGHT BENCHMARK \(Self.count) titles
              entities built: \(built)
              fingerprints: \(fingerprinted)
              ledger: \(ledgerData.count) bytes, encoded in \(encoded), decoded in \(decoded)
              diff of an unchanged library: \(unchanged)
              memory footprint: \(memoryBefore / 1_000_000) MB before, \(Self.footprint() / 1_000_000) MB with every entry built
            """)
        #expect(entries.count == Self.count)

        let pass = entries.prefix(SpotlightPlan.limit)
        let movies = pass.filter { $0.entity.kind == .movie }
        let shows = pass.filter { $0.entity.kind == .show }
        let started = clock.now
        let slowestBatch = max(try await write(movies, of: .movie), try await write(shows, of: .show))
        print("""
            SPOTLIGHT BENCHMARK \(movies.count) movies and \(shows.count) shows handed to Spotlight in batches of \
            \(SpotlightPlan.writeBatch): \(clock.now - started), slowest batch \(slowestBatch)
            """)
    }

    @Test func deletesThemAgain() async throws {
        guard benchmarkMode == "delete" else { return }
        let clock = ContinuousClock()
        let entries = (0..<Self.count).compactMap { SpotlightEntry(Self.item($0), priority: 0, session: session) }
        let deleted = try await clock.measure {
            for kind in [SpotlightEntity.Kind.movie, .show] {
                let ids = entries.filter { $0.entity.kind == kind }.map(\.entity.id)
                for start in stride(from: 0, to: ids.count, by: SpotlightPlan.writeBatch) {
                    try await SpotlightIndex.delete(Array(ids[start..<min(ids.count, start + SpotlightPlan.writeBatch)]), of: kind)
                }
            }
        }
        print("SPOTLIGHT BENCHMARK deleted \(entries.count) entries in batches of \(SpotlightPlan.writeBatch) in \(deleted)")
    }

    /// Writes the entries in the indexer's batches, and says how long the slowest took.
    private func write(_ entries: [SpotlightEntry], of kind: SpotlightEntity.Kind) async throws -> Duration {
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for start in stride(from: 0, to: entries.count, by: SpotlightPlan.writeBatch) {
            let batch = entries[start..<min(entries.count, start + SpotlightPlan.writeBatch)]
            let started = clock.now
            try await SpotlightIndex.write(batch.map(\.entity), of: kind, priority: 0)
            slowest = max(slowest, clock.now - started)
        }
        return slowest
    }

    /// A made-up title shaped like a real one: a name of a few words, a year, a two-sentence
    /// summary, two genres and a poster. Every fifth is a show.
    private static func item(_ number: Int) -> JellyfinItem {
        let words = ["Amber", "Harbor", "Silent", "River", "Copper", "Line", "Winter", "Garden", "Hollow", "Crown", "Ember", "Tide"]
        let name = (0..<(2 + number % 3)).map { words[(number / (1 + $0 * 7) + $0) % words.count] }.joined(separator: " ") + " \(number)"
        var item = JellyfinItem(id: String(format: "%032x", number), name: name, type: number % 5 == 0 ? "Series" : "Movie")
        item.productionYear = 1950 + number % 76
        item.overview = "When \(name) comes to town, nothing stays as it was. A story of friendship, loss and the long road home."
        item.genres = ["Drama", number % 2 == 0 ? "Thriller" : "Comedy"]
        item.imageTags = ["Primary": String(format: "%032x", number * 31)]
        return item
    }

    /// The process's memory footprint, as the system counts it against the app's limit.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
