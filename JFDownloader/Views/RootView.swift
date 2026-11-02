import SwiftUI

struct RootView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Group {
            if let client = accounts.client, let account = accounts.account {
                TabView {
                    Tab("Library", systemImage: "play.rectangle.on.rectangle") {
                        LibraryView(client: client, account: account)
                    }
                    Tab("Downloads", systemImage: "arrow.down.circle") {
                        DownloadsView()
                    }
                    .badge(downloads.jobs.count { $0.status == .active })
                }
                // Each server gets fresh library state.
                .id(account.serverId + account.userId)
            } else {
                LoginView()
            }
        }
        .task { await downloads.trackProgress() }
    }
}
