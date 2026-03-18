#if os(iOS)
import UIKit

final class IOSSystemService: SystemService {
    var deviceName: String {
        UIDevice.current.name
    }

    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    func revealInFileBrowser(url: URL) {
        // No-op on iOS -- Files app handles file browsing
    }
}
#endif
