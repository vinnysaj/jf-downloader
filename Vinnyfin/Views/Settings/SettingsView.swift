import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var accounts
    @Environment(SessionSocket.self) private var socket
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @Environment(DownloadNotifications.self) private var downloadNotifications
    @Environment(\.openURL) private var openURL
    #endif
    #if os(iOS) || os(visionOS)
    @Environment(KeepAwakeAudio.self) private var keepAwake
    #endif
    @State private var confirmingSignOut = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                account
                #if !os(visionOS)
                Section {
                    SettingPicker("Appearance", selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("settings.appearance")
                }
                #endif
                Section {
                    SettingPicker("Streaming Quality", selection: $settings.streamingQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("settings.streamingQuality")
                    Toggle("Transcode When No Version Fits", isOn: $settings.allowTranscoding)
                    Toggle("Adaptive Quality", isOn: $settings.adaptiveQuality)
                        .accessibilityIdentifier("settings.adaptiveQuality")
                    Toggle("Play the Next Episode Automatically", isOn: $settings.autoplayNextEpisode)
                    Toggle("Offer to Skip Intros and Credits", isOn: $settings.showSkipButtons)
                    #if os(tvOS)
                    Toggle("Match Frame Rate and Dynamic Range", isOn: $settings.matchContent)
                    #endif
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Plays the best version up to this quality, untouched. When every version is bigger, the server scales one down, unless transcoding is off. Adaptive Quality switches to a smaller version, or a transcode, when the connection can't keep up. Skip buttons appear for the intros, recaps, previews and credits your server has marked, downloads included.")
                }
                Section("Audio and Subtitles") {
                    SettingPicker("Audio Language", selection: $settings.audioLanguage) {
                        Text("The Video's Default").tag("")
                        ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    SettingPicker("Show Subtitles", selection: $settings.subtitleMode) {
                        ForEach(AppSettings.SubtitleMode.allCases) { Text($0.label).tag($0) }
                    }
                    SettingPicker("Subtitle Language", selection: $settings.subtitleLanguage) {
                        ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    SettingPicker("Subtitle Size", selection: $settings.subtitleScale) {
                        Text("Small").tag(0.8)
                        Text("Standard").tag(1.0)
                        Text("Large").tag(1.25)
                        Text("Extra Large").tag(1.5)
                    }
                }
                #if !os(tvOS)
                Section {
                    SettingPicker("Download Quality", selection: $settings.downloadQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("settings.downloadQuality")
                    Toggle("Delete Watched Episodes", isOn: $settings.deleteWatchedEpisodes)
                        .accessibilityIdentifier("settings.deleteWatched")
                    Stepper("Smart Downloads Keep \(settings.smartDownloadCount) Episodes", value: $settings.smartDownloadCount, in: 1...50)
                    #if os(iOS) || os(visionOS)
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                        .accessibilityIdentifier("settings.diagnostics")
                    #endif
                } header: {
                    Text("Downloads")
                } footer: {
                    #if os(iOS) || os(visionOS)
                    Text("Downloads are always the original file: the version closest to this quality. Watched episodes are deleted once they're watched here or on any of your devices. Diagnostics shows what the system reports about why vinnyfin stopped running.")
                    #else
                    Text("Downloads are always the original file: the version closest to this quality. Watched episodes are deleted once they're watched here or on any of your devices.")
                    #endif
                }
                whenToDownload
                #if os(iOS) || os(visionOS)
                keepRunning
                #endif
                storage
                notifications
                #endif
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    Text("vinnyfin only talks to your Jellyfin server, and to your iCloud, which keeps your servers and most of these settings the same on all your devices. No analytics, no tracking, no accounts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .screenTitle("Settings")
            #if os(macOS)
            // The Mac's Settings window is a window of its own, outside the root view.
            .preferredColorScheme(settings.appearance.colorScheme)
            #endif
            #if os(iOS) || os(visionOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    @ViewBuilder private var account: some View {
        if let account = accounts.account {
            Section {
                LabeledContent("Server", value: account.serverName ?? account.serverURL.host() ?? "Jellyfin")
                LabeledContent("Address", value: account.serverURL.absoluteString)
                LabeledContent("Signed In As", value: account.userName)
                LabeledContent("Remote Control", value: socket.state.label)
                    .accessibilityIdentifier("settings.remoteControl")
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    .accessibilityIdentifier("settings.signOut")
                    .confirmationDialog("Sign out of \(account.serverName ?? "the server")?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            #if os(tvOS)
                            Task { await accounts.signOut() }
                            #else
                            Task { await accounts.signOut(cancelling: downloads) }
                            #endif
                            dismiss()
                        }
                    } message: {
                        #if os(tvOS)
                        Text("You can sign in again at any time.")
                        #else
                        Text("Unfinished downloads are cancelled. Finished downloads stay and still play.")
                        #endif
                    }
            } header: {
                Text("Server")
            } footer: {
                Text("While vinnyfin is open, your other devices and Jellyfin apps can play to this \(Device.name), as \(Device.ownName), and control what plays.")
            }
        }
    }

    #if !os(tvOS)
    @ViewBuilder private var whenToDownload: some View {
        @Bindable var settings = settings
        Section {
            Toggle(Self.cellularLabel, isOn: $settings.downloadOverCellular)
                .accessibilityIdentifier("settings.downloadOverCellular")
            Toggle("Only While Charging", isOn: $settings.downloadOnlyWhileCharging)
                .accessibilityIdentifier("settings.onlyWhileCharging")
        } header: {
            Text("When to Download")
        } footer: {
            Text("Downloads also wait while Low Data Mode is on. vinnyfin starts waiting downloads when the system next lets it, so they can begin a while after you plug in. Download Now on a waiting download starts it anyway.")
        }
    }

    #if os(iOS) || os(visionOS)
    @ViewBuilder private var keepRunning: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Keep Downloads Running", isOn: $settings.keepDownloadsRunning)
                .accessibilityIdentifier("settings.keepDownloadsRunning")
                .onChange(of: settings.keepDownloadsRunning) { _, isOn in
                    if isOn { keepAwake.switchedOn() }
                }
            if settings.keepDownloadsRunning {
                LabeledContent("Sound") {
                    TextField("Sound", text: $settings.keepDownloadsRunningSound, prompt: Text("Optional Web Address"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.keepDownloadsRunningSound")
                }
                KeepAwakeSoundStatus()
                Toggle("Keep Playing After Downloads Finish", isOn: $settings.keepPlayingAfterDownloads)
                    .accessibilityIdentifier("settings.keepPlayingAfterDownloads")
            }
        } footer: {
            Text("Plays audio in the background so \(UIDevice.current.systemName) keeps vinnyfin running until downloads finish. It uses more battery. Sound is the web address of an audio file to play on a loop, such as white noise.")
        }
    }
    #endif

    @ViewBuilder private var storage: some View {
        @Bindable var settings = settings
        Section {
            SettingPicker("Storage Limit", selection: $settings.downloadStorageLimit) {
                ForEach(AppSettings.storageLimitChoices, id: \.self) { gigabytes in
                    Text(gigabytes == 0 ? "No Limit" : DownloadManager.bytes(Int64(gigabytes) * 1_000_000_000)).tag(gigabytes)
                }
            }
            .accessibilityIdentifier("settings.storageLimit")
            StorageUsage()
        } header: {
            Text("Storage")
        } footer: {
            Text("When a download needs room, under the limit or on this \(Device.name), the downloads you watched longest ago are deleted to make it. Unwatched and partly watched downloads are never deleted; if there's still no room, the download waits.")
        }
    }

    @ViewBuilder private var notifications: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Download Notifications", isOn: $settings.downloadNotifications)
                .accessibilityIdentifier("settings.downloadNotifications")
                .onChange(of: settings.downloadNotifications) { _, isOn in
                    if isOn { downloadNotifications.requestAuthorizationIfNeeded() }
                }
            if settings.downloadNotifications, downloadNotifications.isDenied {
                #if os(macOS)
                Text("Notifications are off for vinnyfin in System Settings › Notifications.")
                    .foregroundStyle(.secondary)
                #else
                Button("Turn On Notifications in Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                #endif
            }
        } footer: {
            Text("Tells you when downloads are ready to watch offline, a show's episodes together, and when one needs you: it failed, there's no room for it, or your server has been out of reach for a while.")
        }
        .task { await downloadNotifications.refreshAuthorization() }
    }

    #if os(iOS)
    private static let cellularLabel: LocalizedStringKey = "Download Over Cellular"
    #else
    private static let cellularLabel: LocalizedStringKey = "Download Over Personal Hotspot"
    #endif
    #endif

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#if !os(tvOS)
extension AccountStore {
    /// Signs out, cancelling the downloads that haven't finished: only this sign-in can fetch them.
    func signOut(cancelling downloads: DownloadManager) async {
        downloads.removeUnfinished()
        await signOut()
    }
}
#endif

#if os(iOS) || os(visionOS)
/// How Keep Downloads Running's sound is getting on: fetching, ready, or why it can't be used.
private struct KeepAwakeSoundStatus: View {
    @Environment(KeepAwakeAudio.self) private var keepAwake

    var body: some View {
        switch keepAwake.sound {
        case .silence:
            EmptyView()
        case .fetching:
            HStack(spacing: 8) {
                ProgressView()
                Text("Fetching the sound…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .ready:
            Label("The sound is ready", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let failure):
            Label("\(failure.message) Downloads keep running in silence until it's fixed.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings.keepDownloadsRunningSound.problem")
        }
    }
}
#endif

/// A setting chosen from a list. On Apple TV it's the setting's name and a button with the
/// choice made, which opens a menu of them: a form's picker there lists every choice inline,
/// with a language list running on for screens.
struct SettingPicker<Value: Hashable, Choices: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder let choices: Choices

    init(_ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder choices: () -> Choices) {
        self.title = title
        _selection = selection
        self.choices = choices()
    }

    var body: some View {
        #if os(tvOS)
        LabeledContent(title) {
            Picker(title, selection: $selection) { choices }
                .pickerStyle(.menu)
                .labelsHidden()
        }
        #else
        Picker(title, selection: $selection) { choices }
        #endif
    }
}

/// The open-source software the app is built on, with the notices their licenses ask for.
struct AcknowledgementsView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let summary: String
        let file: String
        var id: String { name }
    }

    /// Static, not stored: Settings builds this page anew each time it renders, and a stored list
    /// SwiftUI can't compare makes each one look changed, which on Apple TV re-renders the two
    /// screens in turn without end once the page is open.
    private static let components = [
        Component(name: "AetherEngine", license: "LGPL-3.0 with App Store exception",
                  summary: "Copyright (C) 2026 Vincent Herbst. The playback engine. Source: github.com/superuser404notfound/AetherEngine",
                  file: "AetherEngine"),
        Component(name: "FFmpeg", license: "LGPL-2.1 or later",
                  summary: "Reads and decodes media, dynamically linked as built by FFmpegBuild, whose build script publishes the configuration and patches. Source: github.com/superuser404notfound/FFmpegBuild and ffmpeg.org",
                  file: "FFmpeg"),
        Component(name: "dav1d", license: "BSD-2-Clause", summary: "Copyright (c) VideoLAN and dav1d authors. Decodes AV1.", file: "dav1d"),
        Component(name: "zimg", license: "WTFPL", summary: "Scales and converts pictures.", file: "zimg"),
        Component(name: "libzvbi", license: "LGPL-2.1, MIT", summary: "Reads teletext and closed captions.", file: "libzvbi"),
        Component(name: "dovi_tool (libdovi)", license: "MIT",
                  summary: "Copyright (c) quietvoid and contributors. Reads Dolby Vision metadata.", file: "libdovi"),
        Component(name: "SMBClient", license: "MIT", summary: "Copyright (c) 2024 Kishikawa Katsumi.", file: "SMBClient"),
        Component(name: "Nuke", license: "MIT", summary: "Copyright (c) 2015-2026 Alexander Grebenyuk. Loads and caches artwork.", file: "Nuke"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.components) { component in
                    NavigationLink {
                        LicenseView(name: component.name, file: component.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(component.name).font(.headline)
                            Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                            Text(component.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                #if os(tvOS)
                Text("Acknowledgements").font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                #endif
            }
        }
        .screenTitle("Acknowledgements")
    }
}

/// A component's license. On Apple TV focus moves through it a paragraph at a time: a page with
/// nothing to focus can't be scrolled with the remote, and Menu there leaves the app instead of
/// going back.
private struct LicenseView: View {
    let name: String
    /// The license's text file in the app's resources.
    let file: String

    var body: some View {
        let text = Self.text(named: file)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if os(tvOS)
                Text(name).font(.title2.bold())
                ForEach(Array(Self.paragraphs(of: text).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.caption.monospaced()).focusable()
                }
                #else
                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                #endif
            }
            .padding()
        }
        .screenTitle(name)
    }

    static func text(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The license text is missing from this build." }
        return text
    }

    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
