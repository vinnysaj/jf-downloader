import SwiftUI
import UniformTypeIdentifiers

/// The first screen without a server: connect to one, or just play a file from this device.
struct WelcomeView: View {
    @Environment(PlayerCoordinator.self) private var player
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloads
    @State private var connecting = false
    @State private var importing = false
    @State private var showingDownloads = false
    #endif

    var body: some View {
        #if os(tvOS)
        LoginView()
        #else
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "play.square.stack.fill")
                .font(.system(size: 76))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("vinnyfin").font(.largeTitle.weight(.bold))
                Text("Your Jellyfin library, and every video on this \(Device.name), in every format.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            VStack(spacing: 12) {
                Button {
                    connecting = true
                } label: {
                    Text("Connect to Jellyfin").frame(maxWidth: 280)
                }
                .buttonStyle(.platformGlassProminent)
                .accessibilityIdentifier("welcome.connect")
                Button {
                    importing = true
                } label: {
                    Text("Play a Video File").frame(maxWidth: 280)
                }
                .buttonStyle(.platformGlass)
                .accessibilityIdentifier("welcome.openFile")
                if !downloads.jobs.isEmpty {
                    Button {
                        showingDownloads = true
                    } label: {
                        Text("Downloads").frame(maxWidth: 280)
                    }
                    .buttonStyle(.platformGlass)
                }
            }
            .controlSize(.large)
            Spacer()
        }
        .padding()
        .sheet(isPresented: $connecting) { LoginView() }
        .sheet(isPresented: $showingDownloads) { DownloadsView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: DownloadsView.videoTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            player.playFile(url)
        }
        #endif
    }
}
