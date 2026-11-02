import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main
struct JFDownloaderApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.accounts)
                .environment(appDelegate.downloads)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}

/// Owns the download queue from launch, including the background launches the system makes
/// only to hand over finished transfers, when no window is ever shown.
final class AppDelegate: NSObject {
    let accounts = AccountStore()
    private(set) lazy var downloads = DownloadManager(accounts: accounts)

    private func startDownloads() {
        let downloads = downloads
        Task { await downloads.run() }
    }
}

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        startDownloads()
    }
}
#else
extension AppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        startDownloads()
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
#endif
