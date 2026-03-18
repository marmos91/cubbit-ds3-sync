@preconcurrency import Foundation

/// A Swift wrapper around `CFNotificationCenterGetDarwinNotifyCenter()` that provides
/// a safe interface for posting and observing Darwin notifications.
///
/// Darwin notifications are a lightweight cross-process signaling mechanism available
/// on both macOS and iOS. They carry no payload -- just a name string -- making them
/// ideal for "something changed, go read the file" patterns.
public final class DarwinNotificationCenter: Sendable {

    /// Shared singleton instance.
    public static let shared = DarwinNotificationCenter()

    /// The underlying Darwin notification center.
    private let center: CFNotificationCenter

    private init() {
        center = CFNotificationCenterGetDarwinNotifyCenter()
    }

    // MARK: - Post

    /// Post a Darwin notification with the given name.
    /// - Parameter name: The notification name string.
    public func post(name: String) {
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Observe

    /// Register an observer for a Darwin notification.
    ///
    /// - Parameters:
    ///   - name: The notification name to observe.
    ///   - callback: A closure invoked each time the notification fires.
    /// - Returns: An observation token. Call `cancel()` on it (or let it deinit) to stop observing.
    public func addObserver(name: String, callback: @escaping @Sendable () -> Void) -> DarwinNotificationObservation {
        let box = Box(callback: callback)
        let pointer = Unmanaged.passRetained(box).toOpaque()

        let cfName = CFNotificationName(name as CFString)
        let callbackFn: CFNotificationCallback = { _, pointer, _, _, _ in
            guard let pointer else { return }
            let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
            box.callback()
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            callbackFn,
            name as CFString,
            nil,
            .deliverImmediately
        )

        return DarwinNotificationObservation(center: center, name: cfName, pointer: pointer)
    }

    // MARK: - AsyncStream

    /// Returns an `AsyncStream<Void>` that yields each time the named Darwin notification fires.
    ///
    /// - Parameter name: The notification name to observe.
    /// - Returns: An async stream that yields `Void` on each notification.
    public func notifications(named name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observation = self.addObserver(name: name) {
                continuation.yield()
            }

            continuation.onTermination = { @Sendable _ in
                observation.cancel()
            }
        }
    }
}

// MARK: - Observation Token

/// An observation token for a Darwin notification. Cancels the observation on `deinit`.
public final class DarwinNotificationObservation: @unchecked Sendable {
    private let center: CFNotificationCenter
    private let name: CFNotificationName
    private let pointer: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var cancelled = false

    init(center: CFNotificationCenter, name: CFNotificationName, pointer: UnsafeMutableRawPointer) {
        self.center = center
        self.name = name
        self.pointer = pointer
    }

    deinit {
        cancel()
    }

    /// Stop observing this notification. Safe to call multiple times.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }

        guard !cancelled else { return }
        cancelled = true

        CFNotificationCenterRemoveObserver(center, pointer, name, nil)
        // Balance the passRetained from addObserver
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }
}

// MARK: - Private Box

/// A box that holds a Swift callback for bridging with the C callback API.
private final class Box: @unchecked Sendable {
    let callback: @Sendable () -> Void

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }
}
