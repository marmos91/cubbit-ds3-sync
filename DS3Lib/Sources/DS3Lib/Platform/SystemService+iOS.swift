#if os(iOS)
import UIKit

@MainActor
final class IOSSystemService: SystemService {
    nonisolated var deviceName: String {
        MainActor.assumeIsolated {
            UIDevice.current.name
        }
    }

    nonisolated func copyToClipboard(_ text: String) {
        MainActor.assumeIsolated {
            UIPasteboard.general.string = text
        }
    }

    nonisolated func revealInFileBrowser(url: URL) {
        // No-op on iOS -- Files app handles file browsing
    }
}
#endif
