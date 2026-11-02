import SwiftUI
import UIKit

@main
struct JFDownloaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.accounts)
                .environment(appDelegate.downloads)
        }
    }
}

/// Owns the download queue from launch, including the background launches the system makes
/// only to hand over finished transfers, when no window is ever shown.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let accounts = AccountStore()
    private(set) lazy var downloads = DownloadManager(accounts: accounts)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let downloads = downloads
        Task { await downloads.run() }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        downloads.handleBackgroundEvents(completion: completionHandler)
    }
}
