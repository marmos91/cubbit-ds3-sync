import Foundation

// MARK: - Supporting types

/// Payload for authentication failure notifications sent from extension to app.
public struct IPCAuthFailure: Codable, Sendable, Equatable {
    /// The File Provider domain identifier
    public let domainId: String

    /// A machine-readable reason string (e.g. "tokenRefreshFailed")
    public let reason: String

    public init(domainId: String, reason: String) {
        self.domainId = domainId
        self.reason = reason
    }
}

/// Payload for extension initialization failure notifications sent from extension to app.
public struct IPCExtensionInitFailure: Codable, Sendable, Equatable {
    /// The File Provider domain identifier
    public let domainId: String

    /// A machine-readable reason string describing the failure
    public let reason: String

    public init(domainId: String, reason: String) {
        self.domainId = domainId
        self.reason = reason
    }
}

// MARK: - IPCService Protocol

/// Protocol defining the inter-process communication interface between
/// the main app and the File Provider extension.
///
/// Both macOS and iOS provide platform-specific implementations that expose
/// the same typed AsyncStream channels for status updates, transfer stats,
/// commands, conflicts, and failure notifications.
public protocol IPCService: Sendable {

    // MARK: - Typed channels (extension -> app)

    /// Stream of drive status changes from the File Provider extension.
    var statusUpdates: AsyncStream<DS3DriveStatusChange> { get }

    /// Stream of transfer speed/progress stats from the File Provider extension.
    var transferSpeeds: AsyncStream<DriveTransferStats> { get }

    /// Stream of conflict notifications from the File Provider extension.
    var conflicts: AsyncStream<ConflictInfo> { get }

    /// Stream of authentication failure notifications from the File Provider extension.
    var authFailures: AsyncStream<IPCAuthFailure> { get }

    /// Stream of extension initialization failure notifications from the File Provider extension.
    var extensionInitFailures: AsyncStream<IPCExtensionInitFailure> { get }

    // MARK: - Typed channels (app -> extension)

    /// Stream of commands from the main app to the File Provider extension.
    var commands: AsyncStream<IPCCommand> { get }

    // MARK: - Post methods

    /// Post a drive status change (typically called by the extension).
    func postStatusChange(_ change: DS3DriveStatusChange) async

    /// Post transfer stats (typically called by the extension).
    func postTransferStats(_ stats: DriveTransferStats) async

    /// Post a command to the extension (typically called by the main app).
    func postCommand(_ command: IPCCommand) async

    /// Post a conflict notification (typically called by the extension).
    func postConflict(_ info: ConflictInfo) async

    /// Post an authentication failure notification (typically called by the extension).
    func postAuthFailure(domainId: String, reason: String) async

    /// Post an extension initialization failure notification (typically called by the extension).
    func postExtensionInitFailure(domainId: String, reason: String) async

    // MARK: - Lifecycle

    /// Start listening for IPC messages. Call once after initialization.
    func startListening() async

    /// Stop listening and finish all streams. Call on teardown.
    func stopListening() async
}

// MARK: - Factory
// The `makeDefaultIPCService()` factory function is provided in IPCService+Factory.swift.
