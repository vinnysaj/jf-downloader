import SwiftUI
import WidgetKit

/// The Downloads widget and control. Both only read the snapshot the app writes to the app
/// group (`DownloadsSnapshot`); the control's switch runs its intent in the app.
@main
struct DownloadsWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadsWidget()
        DownloadsControl()
    }
}
