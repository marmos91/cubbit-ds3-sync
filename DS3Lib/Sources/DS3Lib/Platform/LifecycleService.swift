import Foundation

/// Abstracts app lifecycle management.
/// macOS: SMAppService login item. iOS: BGAppRefreshTask registration.
public protocol LifecycleService: Sendable {
    /// Whether the app is configured to auto-launch (login item on macOS, background refresh on iOS).
    var isAutoLaunchEnabled: Bool { get }

    /// Enable or disable auto-launch behavior.
    /// macOS: registers/unregisters SMAppService. iOS: no-op (user controls via Settings).
    func setAutoLaunch(_ enabled: Bool) throws
}

/// Returns the platform-appropriate ``LifecycleService`` implementation.
public func makeDefaultLifecycleService() -> any LifecycleService {
    #if os(macOS)
    return MacOSLifecycleService()
    #elseif os(iOS)
    return IOSLifecycleService()
    #endif
}
