import Foundation

/// Abstracts platform-specific system services (device info, clipboard, file reveal).
public protocol SystemService: Sendable {
    /// The device's user-facing name (for conflict file naming).
    /// macOS: Host.current().localizedName, iOS: UIDevice.current.name
    var deviceName: String { get }

    /// Copy text to the system clipboard.
    func copyToClipboard(_ text: String)

    /// Reveal a file in the system file browser.
    /// macOS: opens Finder and selects the file. iOS: no-op.
    func revealInFileBrowser(url: URL)
}

/// Returns the platform-appropriate ``SystemService`` implementation.
public func makeDefaultSystemService() -> any SystemService {
    #if os(macOS)
    return MacOSSystemService()
    #elseif os(iOS)
    return IOSSystemService()
    #endif
}
