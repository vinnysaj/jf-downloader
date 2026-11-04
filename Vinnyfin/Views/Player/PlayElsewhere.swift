import GroupActivities
import SwiftUI

/// What plays somewhere else: the playback on screen, or a title from its page.
enum PlayElsewhereSubject {
    case playback(PlayerModel)
    case title(JellyfinItem, mediaSourceId: String?)

    var item: JellyfinItem? {
        switch self {
        case .playback(let model): model.item
        case .title(let item, _): item
        }
    }
}

/// Opens `PlayElsewhereSheet` for a title, from its page. On Apple TV it shows only on a
/// FaceTime call, as SharePlay can't invite anyone from there.
struct PlayElsewhereButton: View {
    let subject: PlayElsewhereSubject

    @Environment(SharePlay.self) private var sharePlay
    @State private var isShowing = false

    var body: some View {
        if PlayElsewhereSheet.isOffered(sharePlay) {
            Button {
                isShowing = true
            } label: {
                Label(PlayElsewhereSheet.title, systemImage: PlayElsewhereSheet.symbol(sharePlay))
            }
            .buttonStyle(.platformGlass)
            .controlSize(.large)
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("playElsewhere")
            .sheet(isPresented: $isShowing) {
                PlayElsewhereSheet(subject: subject) {}
            }
        }
    }
}

/// Watching somewhere else: with the people on a FaceTime call, over SharePlay, and on iPhone,
/// iPad and the Mac on another device, through the server's remote control. The devices that can
/// play now are listed, vinnyfin on Apple TV first, then vinnyfin elsewhere and other Jellyfin
/// apps; vinnyfin devices seen before stay listed while closed, as ones to open first.
struct PlayElsewhereSheet: View {
    let subject: PlayElsewhereSubject
    /// Called once the playback here went to another device, to close the player.
    let onHandedOver: () -> Void

    @Environment(SharePlay.self) private var sharePlay
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    #if os(iOS) || os(macOS)
    @Environment(RemoteControl.self) private var remote
    @State private var targets: [PlayTarget]?
    @State private var known: [KnownDevice] = []
    @State private var loadError: String?
    @State private var sendingTo: PlayTarget.ID?
    @State private var sendError: String?
    #endif

    #if os(iOS) || os(macOS)
    static let title = "Play On or SharePlay"
    #else
    static let title = "SharePlay"
    #endif

    static func isOffered(_ sharePlay: SharePlay) -> Bool {
        #if os(tvOS)
        sharePlay.isEligible || sharePlay.group != nil
        #else
        true
        #endif
    }

    static func symbol(_ sharePlay: SharePlay) -> String {
        #if os(iOS) || os(macOS)
        sharePlay.group == nil ? "tv.and.mediabox" : "shareplay"
        #else
        "shareplay"
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                if let activity { sharePlaySection(activity) }
                #if os(iOS) || os(macOS)
                devices
                #endif
            }
            #if os(iOS) || os(macOS)
            .overlay {
                if targets == nil, loadError == nil { ProgressView() }
            }
            #endif
            .screenTitle(Self.title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
        #if os(iOS) || os(macOS)
        .task { await refreshWhileOpen() }
        #endif
    }

    // MARK: SharePlay

    private var activity: WatchTogether? {
        guard let item = subject.item else { return nil }
        return sharePlay.activity(itemId: item.id, title: item.titleWithYear, subtitle: PlaybackResolver.subtitle(item))
    }

    /// What plays here once the group starts: the title from its page; the playback on screen
    /// plays already.
    private var request: PlaybackRequest? {
        guard case .title(let item, let mediaSourceId) = subject else { return nil }
        return .item(item, mediaSourceId: mediaSourceId)
    }

    @ViewBuilder private func sharePlaySection(_ activity: WatchTogether) -> some View {
        Section {
            if let group = sharePlay.group {
                LabeledContent(group.title, value: group.participantCount == 1 ? "1 Watching" : "\(group.participantCount) Watching")
                ForEach(group.cantWatch, id: \.self) { reason in
                    Label(reason, systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.secondary)
                }
                Button("Leave SharePlay", systemImage: "rectangle.portrait.and.arrow.right") {
                    sharePlay.leave()
                    dismiss()
                }
                Button("End SharePlay for Everyone", systemImage: "xmark.circle", role: .destructive) {
                    sharePlay.endForEveryone()
                    dismiss()
                }
            } else if sharePlay.isEligible {
                Button("Watch Together on This Call", systemImage: "shareplay") {
                    let request = request
                    dismiss()
                    Task { await sharePlay.start(activity, playing: request) }
                }
                .accessibilityIdentifier("sharePlay.start")
            } else {
                #if !os(tvOS)
                ShareLink(item: activity, preview: SharePreview(activity.title)) {
                    Label("Invite to Watch Together", systemImage: "shareplay")
                }
                #endif
            }
        } header: {
            Text("SharePlay")
        } footer: {
            Text("Everyone watches from their own sign-in to \(activity.serverName), in step: pauses, seeks, speed and the next episode are shared.")
        }
    }

    // MARK: Devices

    #if os(iOS) || os(macOS)
    @ViewBuilder private var devices: some View {
        Section {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let targets {
                ForEach(targets) { target in targetRow(target) }
                ForEach(KnownDevice.absent(from: targets, in: known)) { device in knownRow(device) }
                if targets.isEmpty, known.isEmpty {
                    Text("No devices are open. Open vinnyfin on your Apple TV, signed in to \(serverName), and it shows up here.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Play On")
        } footer: {
            Text("Apple TVs and other devices show up here while vinnyfin or another Jellyfin app is open on them, signed in to \(serverName). The server can't open an app that's closed.")
        }
    }

    private var serverName: String {
        accounts.account.map { $0.serverName ?? $0.serverURL.host() ?? "your server" } ?? "your server"
    }

    private func targetRow(_ target: PlayTarget) -> some View {
        Button {
            Task { await send(to: target) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: target.symbol)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).foregroundStyle(.primary)
                    Text(target.detail(signedInAs: accounts.account?.userName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sendingTo == target.id { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(sendingTo != nil)
        .accessibilityIdentifier("playOn.target")
    }

    private func knownRow(_ device: KnownDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).foregroundStyle(.secondary)
                Text("vinnyfin isn't open there. Open it to play on \(device.name).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playOn.closed")
    }

    /// The server lists a device once its app opens, so the list keeps up while it's shown.
    private func refreshWhileOpen() async {
        known = remote.knownDevices
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refresh() async {
        guard let client = accounts.client, let account = accounts.account else { return }
        do {
            let sessions = try await client.controllableSessions(userId: account.userId)
            let found = PlayTarget.targets(from: sessions, excludingDeviceId: accounts.deviceId)
            targets = found
            remote.noteTargets(found)
            known = remote.knownDevices
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = "Couldn't ask the server which devices are open: \(error.localizedDescription)"
            if targets == nil { targets = [] }
        }
    }

    private func send(to target: PlayTarget) async {
        sendingTo = target.id
        defer { sendingTo = nil }
        do {
            switch subject {
            case .playback(let model):
                try await remote.handOver(model, to: target)
                dismiss()
                onHandedOver()
            case .title(let item, let mediaSourceId):
                try await remote.send(item, mediaSourceId: mediaSourceId, from: item.resumeSeconds ?? 0, to: target)
                dismiss()
            }
        } catch {
            sendError = "Couldn't play on \(target.name): \(error.localizedDescription)"
        }
    }
    #endif
}
