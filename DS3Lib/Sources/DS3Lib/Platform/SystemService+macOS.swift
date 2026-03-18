#if os(macOS)
import AppKit

final class MacOSSystemService: SystemService {
    var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealInFileBrowser(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
