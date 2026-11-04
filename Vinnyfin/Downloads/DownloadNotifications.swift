#if !os(tvOS)
import Foundation
import Observation
import OSLog
import UserNotifications
#if os(iOS) || os(visionOS)
import UIKit
#endif

/// Tells the user, through the system's notifications, when downloads are ready to watch
/// offline and when one needs them: it failed, there's no room for it, or the server has been
/// out of reach for over `DownloadAttention.unreachableLimit`.
///
/// Permission is asked the first time someone starts a download, not at launch. A show's
/// episodes share one notification, which counts them as they come ("3 episodes of Port Ellery
/// are ready"): the count carries on from the one still showing, so it holds across launches,
/// and later episodes update it quietly. Downloads finishing together go out together, after
/// `gathering`. What needs attention is one notification too, posted only when something new
/// needs it, and taken away once nothing does. Nothing shows while vinnyfin is in front, where
/// the Downloads screen says it all. Posting keeps the app running long enough to finish
/// (`beginBackgroundTask`), so it works from a background launch: the session's wake, the
/// catch-up and continued-processing tasks.
///
/// Tapping one opens its title through `openedLink`, which the root view handles like any
/// vinnyfin:// link.
@Observable
final class DownloadNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// How long to wait for more downloads finishing together before posting.
    static let gathering: Duration = .seconds(1)
    private static let attentionIdentifier = "attention"
    private nonisolated static let linkKey = "link"
    private static let itemsKey = "items"
    private static let toldKey = "downloads.notifiedAttention"
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "notifications")

    /// A notification's link someone tapped, for the root view to open.
    var openedLink: URL?
    private(set) var authorizationStatus = UNAuthorizationStatus.notDetermined
    /// Someone said no, in the prompt or in system settings, which is the only place to say yes again.
    var isDenied: Bool { authorizationStatus == .denied }
    /// Why notifications couldn't be asked for or posted, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingReady: [DownloadJob] = []
    /// What needs attention, to post once gathering is over.
    @ObservationIgnored private var pendingAttention: AttentionNotice?
    @ObservationIgnored private var isAttentionResolved = false
    @ObservationIgnored private var posting: Task<Void, Never>?
    #if os(iOS) || os(visionOS)
    /// The background time held while posting.
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif
    /// What the user has been told needs attention, kept so a relaunch doesn't tell them again.
    @ObservationIgnored private var told: Set<DownloadAttention>
    @ObservationIgnored private var isRequestingAuthorization = false

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        told = Set((defaults.stringArray(forKey: Self.toldKey) ?? []).compactMap(DownloadAttention.init(key:)))
    }

    /// Takes the notifications' responses from here on. Has to run before the app finishes
    /// launching, to hear about the tap that launched it.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status != authorizationStatus { authorizationStatus = status }
    }

    /// Asks once whether vinnyfin may notify, as someone starts a download or turns the setting on.
    func requestAuthorizationIfNeeded() {
        guard settings.downloadNotifications, !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        Task {
            defer { isRequestingAuthorization = false }
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Self.log.info("Notifications \(granted ? "allowed" : "declined", privacy: .public)")
            } catch {
                problem = "Couldn't ask to send notifications: \(error.localizedDescription)"
            }
            await refreshAuthorization()
        }
    }

    /// A download has been published.
    func ready(_ job: DownloadJob) {
        pendingReady.append(job)
        postSoon()
    }

    /// The state of the downloads, after each change: anything newly in need of attention is
    /// told, and once nothing is, the notification goes.
    func attentionChanged(jobs: [DownloadJob], waits: [UUID: DownloadWait], isNetworkReachable: Bool, serverName: String?, now: Date) {
        let current = DownloadAttention.current(jobs: jobs, waits: waits, isNetworkReachable: isNetworkReachable, now: now)
        let isNew = !current.isSubset(of: told)
        guard current != told else { return }
        told = current
        defaults.set(current.map(\.key).sorted(), forKey: Self.toldKey)
        if current.isEmpty {
            pendingAttention = nil
            isAttentionResolved = true
        } else if isNew {
            pendingAttention = AttentionNotice(current, jobs: jobs, waits: waits, serverName: serverName)
            isAttentionResolved = false
        } else {
            return
        }
        postSoon()
    }

    // MARK: Posting

    private func postSoon() {
        guard posting == nil else { return }
        #if os(iOS) || os(visionOS)
        // Given back when the system wants it, or it ends the app.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Download notifications") { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
        posting = Task {
            try? await Task.sleep(for: Self.gathering)
            await post()
            posting = nil
            #if os(iOS) || os(visionOS)
            endBackgroundTask()
            #endif
            if !pendingReady.isEmpty || pendingAttention != nil || isAttentionResolved { postSoon() }
        }
    }

    #if os(iOS) || os(visionOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private func post() async {
        let ready = pendingReady
        let attention = pendingAttention
        let isResolved = isAttentionResolved
        pendingReady = []
        pendingAttention = nil
        isAttentionResolved = false
        let center = UNUserNotificationCenter.current()
        if isResolved { center.removeDeliveredNotifications(withIdentifiers: [Self.attentionIdentifier]) }
        guard settings.downloadNotifications, !ready.isEmpty || attention != nil else { return }
        await refreshAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        var requests: [UNNotificationRequest] = []
        if !ready.isEmpty {
            var delivered: [String: [String]] = [:]
            for notification in await center.deliveredNotifications() {
                let request = notification.request
                if let items = request.content.userInfo[Self.itemsKey] as? [String] { delivered[request.identifier] = items }
            }
            for notice in ReadyNotice.notices(for: ready, delivered: delivered) {
                let content = UNMutableNotificationContent()
                content.body = notice.body
                content.threadIdentifier = notice.identifier
                content.userInfo = [Self.linkKey: notice.link.absoluteString, Self.itemsKey: notice.itemIds]
                if notice.isUpdate {
                    content.interruptionLevel = .passive
                } else {
                    content.sound = .default
                }
                requests.append(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
            }
        }
        if let attention {
            let content = UNMutableNotificationContent()
            content.title = attention.title
            content.body = attention.body
            content.sound = .default
            content.threadIdentifier = Self.attentionIdentifier
            if let link = attention.link { content.userInfo = [Self.linkKey: link.absoluteString] }
            requests.append(UNNotificationRequest(identifier: Self.attentionIdentifier, content: content, trigger: nil))
        }
        for request in requests {
            do {
                try await center.add(request)
                Self.log.info("Posted \(request.identifier, privacy: .public): \(request.content.body, privacy: .public)")
            } catch {
                problem = "Couldn't post a notification: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Responses

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = (response.notification.request.content.userInfo[Self.linkKey] as? String).flatMap(URL.init(string:))
        else { return }
        await open(link)
    }

    private func open(_ link: URL) {
        openedLink = link
    }
}

// MARK: Content

/// A notification that downloads are ready: one per film, one per show for its episodes.
nonisolated struct ReadyNotice: Equatable, Sendable {
    let identifier: String
    let body: String
    let link: URL
    /// Every item it covers, those of the notification it replaces included.
    let itemIds: [String]
    /// It replaces one still showing, so it comes in quietly.
    let isUpdate: Bool

    /// The notices for downloads just published, counting on from those still showing:
    /// `delivered` is the items each notification showing covers, by its identifier.
    static func notices(for jobs: [DownloadJob], delivered: [String: [String]]) -> [ReadyNotice] {
        var groups: [(key: String, jobs: [DownloadJob])] = []
        for job in jobs {
            let key = job.isEpisode ? "ready.series.\(job.seriesId ?? job.item?.seriesName ?? job.itemId)" : "ready.item.\(job.itemId)"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].jobs.append(job)
            } else {
                groups.append((key, [job]))
            }
        }
        return groups.map { key, jobs in
            let earlier = delivered[key] ?? []
            var itemIds = earlier
            for job in jobs where !itemIds.contains(job.itemId) { itemIds.append(job.itemId) }
            let last = jobs[jobs.count - 1]
            let body: String
            let link: URL
            if itemIds.count > 1, last.isEpisode, let seriesId = last.seriesId {
                let series = last.item?.seriesName ?? "a show"
                body = "\(itemIds.count) episodes of \(series) are ready to watch offline."
                link = AppLink(.open, JellyfinItem(id: seriesId, name: series, type: "Series")).url
            } else {
                body = "\(last.shortName) is ready to watch offline."
                link = AppLink(.open, last.item ?? JellyfinItem(id: last.itemId, name: last.title, type: last.isEpisode ? "Episode" : "Movie")).url
            }
            return ReadyNotice(identifier: key, body: body, link: link, itemIds: itemIds, isUpdate: delivered[key] != nil)
        }
    }
}

/// Something about the downloads the user has to act on.
nonisolated enum DownloadAttention: Hashable, Sendable {
    case failed(UUID)
    case space(UUID)
    /// The server has been out of reach for over `unreachableLimit`.
    case unreachable

    static let unreachableLimit: TimeInterval = 60 * 60

    /// What needs attention now. The server only counts as out of reach while the device is
    /// on a network: offline, waiting says nothing about it.
    static func current(jobs: [DownloadJob], waits: [UUID: DownloadWait], isNetworkReachable: Bool, now: Date) -> Set<DownloadAttention> {
        var current: Set<DownloadAttention> = []
        for job in jobs {
            if job.status == .failed { current.insert(.failed(job.id)) }
            guard job.status == .active else { continue }
            if case .space = waits[job.id] { current.insert(.space(job.id)) }
            if isNetworkReachable, let since = job.serverUnreachableSince, now.timeIntervalSince(since) > unreachableLimit {
                current.insert(.unreachable)
            }
        }
        return current
    }

    var key: String {
        switch self {
        case .failed(let id): "failed:\(id.uuidString)"
        case .space(let id): "space:\(id.uuidString)"
        case .unreachable: "unreachable"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count == 2 ? UUID(uuidString: parts[1]) : nil) {
        case ("failed", let id?): self = .failed(id)
        case ("space", let id?): self = .space(id)
        case ("unreachable", nil) where parts.count == 1: self = .unreachable
        default: return nil
        }
    }
}

/// The one notification about what needs attention, in plain words with what to do.
nonisolated struct AttentionNotice: Equatable, Sendable {
    let title: String
    let body: String
    /// The title concerned, when it's one download.
    let link: URL?

    init(_ attention: Set<DownloadAttention>, jobs: [DownloadJob], waits: [UUID: DownloadWait], serverName: String?) {
        var failed: [DownloadJob] = []
        var short: [(job: DownloadJob, needed: Int64)] = []
        let unreachable = attention.contains(.unreachable)
        // In list order, so the first named is the one that would download first.
        for job in jobs {
            if attention.contains(.failed(job.id)) { failed.append(job) }
            if attention.contains(.space(job.id)), case .space(let needed) = waits[job.id] { short.append((job, needed)) }
        }
        let server = serverName ?? "your server"
        var sentences: [String] = []
        if let first = failed.first {
            sentences.append(failed.count == 1
                ? "\(first.shortName) couldn't download\(first.lastError.map { ": \($0)" } ?? ".")"
                : "\(failed.count) downloads couldn't finish. Open vinnyfin to retry them.")
        }
        if let first = short.first {
            let needed = first.needed.formatted(.byteCount(style: .file))
            sentences.append(short.count == 1
                ? "\(first.job.shortName) needs \(needed) more space."
                : "\(short.count) downloads are waiting for space; the next needs \(needed) more.")
            sentences.append("Delete downloads you've finished with or other things you don't need, or raise the storage limit in vinnyfin's settings.")
        }
        if unreachable {
            sentences.append("vinnyfin hasn't been able to reach \(server) for over an hour. Downloads carry on once it can.")
        }
        let kinds = [!failed.isEmpty, !short.isEmpty, unreachable].count(where: \.self)
        if kinds > 1 {
            title = "Downloads Need Attention"
        } else if !failed.isEmpty {
            title = failed.count == 1 ? "Download Failed" : "Downloads Failed"
        } else if !short.isEmpty {
            title = "Not Enough Space for Downloads"
        } else {
            title = "Can't Reach \(server)"
        }
        body = sentences.joined(separator: " ")
        let only = failed.count + short.count == 1 ? (failed.first ?? short.first?.job) : nil
        link = only.map { job in AppLink(.open, job.item ?? JellyfinItem(id: job.itemId, name: job.title, type: job.isEpisode ? "Episode" : "Movie")).url }
    }
}
#endif
