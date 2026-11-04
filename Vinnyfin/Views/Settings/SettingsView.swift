import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
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
                    Toggle("Play the Next Episode Automatically", isOn: $settings.autoplayNextEpisode)
                    Toggle("Offer to Skip Intros and Credits", isOn: $settings.showSkipButtons)
                    #if os(tvOS)
                    Toggle("Match Frame Rate and Dynamic Range", isOn: $settings.matchContent)
                    #endif
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Plays the best version up to this quality, untouched. When every version is bigger, the server scales one down, unless transcoding is off. Skip buttons appear for the intros, recaps, previews and credits your server has marked, downloads included.")
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
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Downloads are always the original file: the version closest to this quality. Watched episodes are deleted once they're watched here or on any of your devices.")
                }
                #endif
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    Text("vinnyfin only talks to your Jellyfin server. No analytics, no tracking, no accounts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
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
            Section("Server") {
                LabeledContent("Server", value: account.serverName ?? account.serverURL.host() ?? "Jellyfin")
                LabeledContent("Address", value: account.serverURL.absoluteString)
                LabeledContent("Signed In As", value: account.userName)
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    .accessibilityIdentifier("settings.signOut")
                    .confirmationDialog("Sign out of \(account.serverName ?? "the server")?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            #if !os(tvOS)
                            downloads.removeUnfinished()
                            #endif
                            Task { await accounts.signOut() }
                            dismiss()
                        }
                    } message: {
                        #if os(tvOS)
                        Text("You can sign in again at any time.")
                        #else
                        Text("Unfinished downloads are cancelled. Finished downloads stay and still play.")
                        #endif
                    }
            }
        }
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

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

    private let components = [
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
        List(components) { component in
            NavigationLink {
                ScrollView {
                    Text(Self.text(named: component.file))
                        .font(.caption.monospaced())
                        .padding()
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                }
                .navigationTitle(component.name)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.name).font(.headline)
                    Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                    Text(component.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }

    static func text(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The license text is missing from this build." }
        return text
    }
}
