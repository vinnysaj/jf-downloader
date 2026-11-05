#if !os(tvOS)
import Foundation
import Network

/// The network the device is on, as the downloads' rules see it.
nonisolated struct NetworkConditions: Equatable, Sendable {
    var isReachable: Bool
    /// Cellular, or a Personal Hotspot.
    var isExpensive: Bool
    /// Low Data Mode is on for it.
    var isConstrained: Bool
    var usesCellular: Bool

    /// Until the path monitor has spoken: assumed reachable, so nothing waits on a guess.
    static let unknown = NetworkConditions(isReachable: true, isExpensive: false, isConstrained: false, usesCellular: false)

    init(isReachable: Bool, isExpensive: Bool, isConstrained: Bool, usesCellular: Bool) {
        self.isReachable = isReachable
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.usesCellular = usesCellular
    }

    init(_ path: NWPath) {
        isReachable = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        usesCellular = path.usesInterfaceType(.cellular)
    }
}

/// The networks a transfer may use. A background session's configuration is fixed when it's
/// made, so each request carries its own, and the system holds the transfer until the device is
/// on a network it allows, whether or not the app runs.
nonisolated struct NetworkAccess: Equatable, Sendable {
    var allowsCellular: Bool
    var allowsExpensive: Bool
    var allowsConstrained: Bool

    static let any = NetworkAccess(allowsCellular: true, allowsExpensive: true, allowsConstrained: true)

    init(allowsCellular: Bool, allowsExpensive: Bool, allowsConstrained: Bool) {
        self.allowsCellular = allowsCellular
        self.allowsExpensive = allowsExpensive
        self.allowsConstrained = allowsConstrained
    }

    /// What a request was made with; any network for none.
    init(_ request: URLRequest?) {
        guard let request else {
            self = .any
            return
        }
        self.init(allowsCellular: request.allowsCellularAccess, allowsExpensive: request.allowsExpensiveNetworkAccess,
                  allowsConstrained: request.allowsConstrainedNetworkAccess)
    }

    func apply(to request: inout URLRequest) {
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsExpensive
        request.allowsConstrainedNetworkAccess = allowsConstrained
    }

    /// Whether the system lets a transfer with these use `network`.
    func allows(_ network: NetworkConditions) -> Bool {
        !(network.usesCellular && !allowsCellular) && !(network.isExpensive && !allowsExpensive)
            && !(network.isConstrained && !allowsConstrained)
    }

    var summary: String {
        self == .any ? "any network" : allowsExpensive ? "any network outside Low Data Mode" : "Wi-Fi only"
    }
}

/// Why a download that could otherwise go on waits.
nonisolated enum DownloadWait: Equatable, Sendable {
    /// Download Over Cellular is off, and the device is on cellular or a Personal Hotspot.
    case wifi
    /// Low Data Mode is on for the network the device is on.
    case lowDataMode
    /// Only While Charging is on, and the device isn't on power.
    case power
    /// There's no room for it under the storage limit or on the device, even once every watched
    /// download is deleted; it needs this many bytes more.
    case space(needed: Int64)

    /// The rules hold it back rather than the device: Download Now lifts them.
    var isRule: Bool {
        if case .space = self { false } else { true }
    }

    /// Its transfers can go to the session to wait for a network they may use; the app holds
    /// back the others.
    var isNetwork: Bool { self == .wifi || self == .lowDataMode }
}

extension DownloadWait {
    /// In the words of the download's status line.
    var status: String {
        switch self {
        case .wifi: "Waiting for Wi-Fi"
        case .lowDataMode: "Waiting while Low Data Mode is on"
        case .power: "Waiting until your \(Device.name) is charging"
        case .space(let needed): "Waiting for space: \(needed.formatted(.byteCount(style: .file))) more needed"
        }
    }

    var systemImage: String {
        switch self {
        case .wifi: "wifi"
        case .lowDataMode: "arrow.down.circle.dotted"
        case .power: "powerplug"
        case .space: "externaldrive.badge.exclamationmark"
        }
    }
}

/// When and where downloads may run, from Settings. Download Now lifts the network rules and
/// Only While Charging for one download; nothing lifts the storage limit.
nonisolated struct DownloadRules: Equatable, Sendable {
    var downloadsOverCellular: Bool
    var onlyWhileCharging: Bool
    /// Bytes downloads may take up in all, finished or partial; nil for no limit.
    var storageLimit: Int64?

    init(downloadsOverCellular: Bool = true, onlyWhileCharging: Bool = false, storageLimit: Int64? = nil) {
        self.downloadsOverCellular = downloadsOverCellular
        self.onlyWhileCharging = onlyWhileCharging
        self.storageLimit = storageLimit
    }

    /// The networks the job's transfers may use. Low Data Mode always holds downloads back.
    func access(for job: DownloadJob) -> NetworkAccess {
        if job.ignoresRules { return .any }
        return NetworkAccess(allowsCellular: downloadsOverCellular, allowsExpensive: downloadsOverCellular, allowsConstrained: false)
    }

    /// What holds the job back right now, other than room: power first, then the network. Nil
    /// when nothing does, or when there's no network at all, which isn't a rule. Power the
    /// device can't report on doesn't hold anything back.
    func wait(for job: DownloadJob, network: NetworkConditions, isOnPower: Bool?) -> DownloadWait? {
        guard !job.ignoresRules else { return nil }
        if onlyWhileCharging, isOnPower == false { return .power }
        guard network.isReachable else { return nil }
        let access = access(for: job)
        if (network.usesCellular && !access.allowsCellular) || (network.isExpensive && !access.allowsExpensive) { return .wifi }
        if network.isConstrained && !access.allowsConstrained { return .lowDataMode }
        return nil
    }

    /// Whether the system should wait for power before launching the app to catch up on
    /// `queue`, for Only While Charging. Not when one of them is a download someone chose
    /// Download Now for.
    func catchUpRequiresExternalPower(for queue: [DownloadJob]) -> Bool {
        onlyWhileCharging && !queue.contains(where: \.ignoresRules)
    }
}

extension DownloadRules {
    init(_ settings: AppSettings) {
        self.init(downloadsOverCellular: settings.downloadOverCellular, onlyWhileCharging: settings.downloadOnlyWhileCharging,
                  storageLimit: settings.downloadStorageLimit > 0 ? Int64(settings.downloadStorageLimit) * 1_000_000_000 : nil)
    }
}

// MARK: Storage

/// How a finished download has been watched since it was downloaded.
nonisolated enum WatchState: Equatable, Sendable {
    /// Not since it was downloaded: kept, if it was watched before, to watch again.
    case unwatched
    case inProgress
    case watched(at: Date)

    var isWatched: Bool {
        if case .watched = self { true } else { false }
    }
}

nonisolated extension DownloadJob {
    /// The latest record of watching since the download finished decides, this device's or
    /// the server's (as `item` last heard it): a rewatch the server has partway is in progress,
    /// though it stays marked watched there.
    func watchState(local: WatchHistory.Entry?) -> WatchState {
        guard status == .completed, let downloadedAt = completedAt else { return .unwatched }
        var latest: (date: Date, played: Bool, partway: Bool)?
        if let local, local.updatedAt > downloadedAt {
            latest = (local.updatedAt, local.played, !local.played && local.position > 0)
        }
        if let data = item?.userData, let played = item?.lastPlayedDate, played > downloadedAt, played > latest?.date ?? .distantPast {
            latest = (played, data.played == true, (data.playbackPositionTicks ?? 0) > 0)
        }
        guard let latest else { return .unwatched }
        if latest.partway { return .inProgress }
        return latest.played ? .watched(at: latest.date) : .unwatched
    }
}

/// Room for the downloads queued, under the storage limit and on the device, and what to delete
/// to make it. One policy for every deletion that isn't asked for: only downloads watched since
/// they were downloaded go, the one watched longest ago first, and only as many as the queue
/// needs. Unwatched and partly watched downloads stay.
nonisolated enum StorageBudget {
    /// What someone can do about a download waiting for room.
    static func advice(hasLimit: Bool) -> String {
        hasLimit
            ? "Delete downloads you've finished with or other things you don't need, or raise the storage limit in vinnyfin's settings."
            : "Delete downloads you've finished with or other things you don't need."
    }

    struct Deletable: Equatable, Sendable {
        let id: UUID
        let bytes: Int64
    }

    struct Outcome: Equatable, Sendable {
        /// Watched downloads to delete, in order, to make room.
        var deletions: [UUID] = []
        /// Queued downloads that don't fit even so, with how many bytes more each needs.
        var shortfalls: [UUID: Int64] = [:]
    }

    /// Walks the queue in order, each download that fits keeping its room. One that doesn't
    /// takes room from `deletable` (oldest watched first) if that's enough, and otherwise
    /// waits, deleting nothing and keeping no room, so a smaller one behind it can still go.
    /// `bytesSoFar` is what each queued download already has (`DownloadJob.bytesSoFar`), its
    /// partial file's bytes when it's missing; `used` is what downloads take up now, finished
    /// files and partial ones; `available` is the device's free space, nil when it can't say.
    /// A download whose size neither the listing nor the server has given yet isn't held back.
    static func plan(queue: [DownloadJob], bytesSoFar: [UUID: Int64], used: Int64, available: Int64?, limit: Int64?,
                     deletable: [Deletable]) -> Outcome {
        // Room that's unlimited stays so: deleting a file makes as much room under the limit as
        // on the device, so the shortfall goes down by its size either way.
        var limitRoom = limit.map { $0 - used } ?? .max
        var deviceRoom = available ?? .max
        var reserved: Int64 = 0
        var candidates = deletable[...]
        var deletableBytes = deletable.reduce(0) { $0 + $1.bytes }
        var outcome = Outcome()
        func shortfall(_ need: Int64) -> Int64 {
            max(reserved + need - limitRoom, reserved + need - deviceRoom, 0)
        }
        for job in queue {
            guard let total = job.displayTotalBytes else { continue }
            let need = max(0, total - (bytesSoFar[job.id] ?? job.bytesOnDisk))
            if shortfall(need) <= deletableBytes {
                while shortfall(need) > 0, let next = candidates.popFirst() {
                    outcome.deletions.append(next.id)
                    deletableBytes -= next.bytes
                    if limitRoom != .max { limitRoom += next.bytes }
                    if deviceRoom != .max { deviceRoom += next.bytes }
                }
            }
            let missing = shortfall(need)
            if missing > 0 {
                outcome.shortfalls[job.id] = missing
            } else {
                reserved += need
            }
        }
        return outcome
    }
}
#endif
