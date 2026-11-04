import Foundation

/// Loads named by what they load, run a few at a time so a big server isn't asked for
/// everything at once, in the order they're wanted. A load that stops being wanted is dropped
/// before its turn, or cancelled if it's under way.
@MainActor
final class LoadQueue<Key: Hashable> {
    /// How many loads run at once.
    let width: Int
    private let load: @MainActor (Key) async -> Void
    private var waiting: [Key] = []
    private var running: [Key: (run: Int, task: Task<Void, Never>)] = [:]
    private var runs = 0

    init(width: Int, load: @escaping @MainActor (Key) async -> Void) {
        self.width = width
        self.load = load
    }

    /// What's waiting for its turn, first first.
    var queued: [Key] { waiting }

    /// What's under way.
    var underWay: Set<Key> { Set(running.keys) }

    /// Lines up the keys that are neither waiting nor under way, in order.
    func want(_ keys: [Key]) {
        for key in keys where running[key] == nil && !waiting.contains(key) {
            waiting.append(key)
        }
        pump()
    }

    /// Drops the waiting loads, and cancels those under way, that `keep` turns down.
    func retain(where keep: (Key) -> Bool) {
        waiting.removeAll { !keep($0) }
        for key in running.keys where !keep(key) {
            running.removeValue(forKey: key)?.task.cancel()
        }
        pump()
    }

    func cancelAll() {
        waiting.removeAll()
        for entry in running.values { entry.task.cancel() }
        running.removeAll()
    }

    private func pump() {
        while running.count < width, !waiting.isEmpty {
            let key = waiting.removeFirst()
            runs += 1
            let run = runs
            let load = load
            running[key] = (run, Task { [weak self] in
                await load(key)
                self?.finish(key, run: run)
            })
        }
    }

    private func finish(_ key: Key, run: Int) {
        // A load cancelled and wanted again meanwhile is another run, still under way.
        guard running[key]?.run == run else { return }
        running.removeValue(forKey: key)
        pump()
    }
}
