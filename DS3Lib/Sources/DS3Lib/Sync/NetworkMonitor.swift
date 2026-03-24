import Foundation
import Network
import os.log

/// Async-friendly NWPathMonitor wrapper for connectivity detection.
/// Used by SyncEngine to pause operations when offline and auto-recover when connectivity returns.
public actor NetworkMonitor {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.sync.rawValue)

    public private(set) var isConnected: Bool = true
    private var continuation: AsyncStream<Bool>.Continuation?

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "io.cubbit.DS3Drive.NetworkMonitor")
    }

    /// Starts monitoring network connectivity. Call once at initialization.
    public func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { [weak self] in
                await self?.updateStatus(connected)
            }
        }
        monitor.start(queue: queue)
        logger.info("Network monitoring started")
    }

    /// An AsyncStream that yields connectivity state changes.
    public var connectivityUpdates: AsyncStream<Bool> {
        AsyncStream { continuation in
            self.continuation = continuation
            // Yield current state immediately
            continuation.yield(isConnected)
        }
    }

    private func updateStatus(_ connected: Bool) {
        let changed = isConnected != connected
        isConnected = connected
        if changed {
            logger.info("Network connectivity changed: \(connected ? "connected" : "disconnected")")
            continuation?.yield(connected)
        }
    }

    /// Stops monitoring. Call during cleanup/invalidation.
    public func stopMonitoring() {
        monitor.cancel()
        continuation?.finish()
        logger.info("Network monitoring stopped")
    }
}
