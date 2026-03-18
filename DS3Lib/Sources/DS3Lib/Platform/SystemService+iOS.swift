#if os(iOS)
import UIKit

final class IOSSystemService: SystemService {
    var deviceName: String {
        processInfo.hostName
    }

    private let processInfo = ProcessInfo.processInfo

    func copyToClipboard(_ text: String) {
        Task { @MainActor in
            UIPasteboard.general.string = text
        }
    }

    func revealInFileBrowser(url: URL) {
        // No-op on iOS -- Files app handles file browsing
    }
}
#endif
