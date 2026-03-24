import Foundation

/// Identifies the distribution channel through which the app was installed.
/// Used to determine update behavior — only `.directDownload` uses in-app updates via Sparkle;
/// all other channels show a notification directing users to the appropriate store or tool.
public enum DistributionChannel: String, Sendable {
    /// Installed via TestFlight (sandbox receipt present)
    case testFlight
    /// Installed from the App Store (valid receipt, not sandbox)
    case appStore
    #if os(macOS)
        /// Installed via Homebrew Cask
        case homebrew
        /// Direct download (DMG from GitHub Releases) — the Sparkle update channel
        case directDownload
    #endif

    /// Cached value computed once at launch.
    @available(macOS, deprecated: 15.0, message: "Uses deprecated appStoreReceiptURL for backwards compatibility")
    @available(iOS, deprecated: 18.0, message: "Uses deprecated appStoreReceiptURL for backwards compatibility")
    private static let _detected: DistributionChannel = {
        // 1. TestFlight: sandbox receipt
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           receiptURL.lastPathComponent == "sandboxReceipt" {
            return .testFlight
        }

        // 2. App Store: receipt exists and is not sandbox
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           FileManager.default.fileExists(atPath: receiptURL.path) {
            return .appStore
        }

        #if os(macOS)
            // 3. Homebrew: app bundle lives inside a Caskroom path, or cask directory exists
            let bundlePath = Bundle.main.bundlePath
            let caskroomPaths = [
                "/opt/homebrew/Caskroom/cubbit-ds3-drive",
                "/usr/local/Caskroom/cubbit-ds3-drive"
            ]
            if bundlePath.contains("/Caskroom/") ||
                caskroomPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                return .homebrew
            }

            // 4. Fallback: direct download (Sparkle channel)
            return .directDownload
        #else
            // iOS fallback: if no receipt at all, assume TestFlight (dev/beta builds)
            return .testFlight
        #endif
    }()

    /// Detects the current distribution channel. Result is cached after first call.
    public static func detect() -> DistributionChannel {
        _detected
    }

    /// Human-readable display name for the channel.
    public var displayName: String {
        switch self {
        case .testFlight: return "TestFlight"
        case .appStore: return "App Store"
        #if os(macOS)
            case .homebrew: return "Homebrew"
            case .directDownload: return "Direct Download"
        #endif
        }
    }

    /// Whether this channel supports in-app automatic updates (Sparkle).
    public var supportsInAppUpdate: Bool {
        #if os(macOS)
            return self == .directDownload
        #else
            return false
        #endif
    }
}
