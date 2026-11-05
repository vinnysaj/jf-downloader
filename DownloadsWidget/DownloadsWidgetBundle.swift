import SwiftUI
import WidgetKit

/// The app's widgets and control. The Downloads widget and control only read the snapshot the
/// app writes to the app group (`DownloadsSnapshot`), and the control's switch runs its intent in
/// the app. The Continue Watching and Next Up widgets read the sign-in from the app group and ask
/// the server themselves (`UpNextWidgets`).
@main
struct DownloadsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        NextUpWidget()
        DownloadsWidget()
        DownloadsControl()
    }
}
