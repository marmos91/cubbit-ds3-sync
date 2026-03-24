#if os(macOS)
    import Foundation

    /// macOS implementation of ``IPCService`` that wraps `DistributedNotificationCenter`
    /// in typed `AsyncStream` channels.
    ///
    /// Each notification name from `DefaultSettings.Notifications` is observed via
    /// `DistributedNotificationCenter.default()` and decoded into the corresponding
    /// strongly-typed payload, then yielded into the appropriate stream continuation.
    final class MacOSIPCService: IPCService, @unchecked Sendable {
        // MARK: - Streams

        let statusUpdates: AsyncStream<DS3DriveStatusChange>
        let transferSpeeds: AsyncStream<DriveTransferStats>
        let commands: AsyncStream<IPCCommand>
        let conflicts: AsyncStream<ConflictInfo>
        let authFailures: AsyncStream<IPCAuthFailure>
        let extensionInitFailures: AsyncStream<IPCExtensionInitFailure>

        // MARK: - Continuations

        private let statusContinuation: AsyncStream<DS3DriveStatusChange>.Continuation
        private let transferContinuation: AsyncStream<DriveTransferStats>.Continuation
        private let commandContinuation: AsyncStream<IPCCommand>.Continuation
        private let conflictContinuation: AsyncStream<ConflictInfo>.Continuation
        private let authFailureContinuation: AsyncStream<IPCAuthFailure>.Continuation
        private let extensionInitFailureContinuation: AsyncStream<IPCExtensionInitFailure>.Continuation

        // MARK: - Observers

        /// Tokens returned by `addObserver(forName:...)` for cleanup.
        private var observers: [NSObjectProtocol] = []

        // MARK: - Init

        init() {
            (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: DS3DriveStatusChange.self)
            (transferSpeeds, transferContinuation) = AsyncStream.makeStream(of: DriveTransferStats.self)
            (commands, commandContinuation) = AsyncStream.makeStream(of: IPCCommand.self)
            (conflicts, conflictContinuation) = AsyncStream.makeStream(of: ConflictInfo.self)
            (authFailures, authFailureContinuation) = AsyncStream.makeStream(of: IPCAuthFailure.self)
            (extensionInitFailures, extensionInitFailureContinuation) = AsyncStream
                .makeStream(of: IPCExtensionInitFailure.self)
        }

        // MARK: - Lifecycle

        func startListening() async {
            let center = DistributedNotificationCenter.default()
            let decoder = JSONDecoder()

            registerJSONObserver(
                center: center,
                decoder: decoder,
                name: .driveStatusChanged,
                continuation: statusContinuation
            )
            registerJSONObserver(
                center: center,
                decoder: decoder,
                name: .driveTransferStats,
                continuation: transferContinuation
            )
            registerJSONObserver(
                center: center, decoder: decoder,
                name: NSNotification.Name(DefaultSettings.Notifications.command),
                continuation: commandContinuation
            )
            registerJSONObserver(
                center: center,
                decoder: decoder,
                name: .conflictDetected,
                continuation: conflictContinuation
            )
            registerAuthObserver(center: center)
            registerExtInitObserver(center: center)
        }

        func stopListening() async {
            let center = DistributedNotificationCenter.default()
            for observer in observers {
                center.removeObserver(observer)
            }
            observers.removeAll()

            statusContinuation.finish()
            transferContinuation.finish()
            commandContinuation.finish()
            conflictContinuation.finish()
            authFailureContinuation.finish()
            extensionInitFailureContinuation.finish()
        }

        // MARK: - Post methods

        func postStatusChange(_ change: DS3DriveStatusChange) async {
            postJSON(change, notificationName: .driveStatusChanged)
        }

        func postTransferStats(_ stats: DriveTransferStats) async {
            postJSON(stats, notificationName: .driveTransferStats)
        }

        func postCommand(_ command: IPCCommand) async {
            postJSON(command, notificationName: NSNotification.Name(DefaultSettings.Notifications.command))
        }

        func postConflict(_ info: ConflictInfo) async {
            postJSON(info, notificationName: .conflictDetected)
        }

        func postAuthFailure(domainId: String, reason: String) async {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(DefaultSettings.Notifications.authFailure),
                object: domainId,
                userInfo: ["reason": reason],
                deliverImmediately: true
            )
        }

        func postExtensionInitFailure(domainId: String, reason: String) async {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(DefaultSettings.Notifications.extensionInitFailed),
                object: domainId,
                userInfo: ["reason": reason],
                deliverImmediately: true
            )
        }

        // MARK: - Private helpers

        /// Register a `DistributedNotificationCenter` observer that decodes JSON from `notification.object`.
        private func registerJSONObserver<T: Decodable & Sendable>(
            center: DistributedNotificationCenter,
            decoder: JSONDecoder,
            name: NSNotification.Name,
            continuation: AsyncStream<T>.Continuation
        ) {
            let obs = center.addObserver(forName: name, object: nil, queue: nil) { notification in
                guard let jsonString = notification.object as? String else { return }
                guard let data = jsonString.data(using: .utf8) else { return }
                guard let value = try? decoder.decode(T.self, from: data) else { return }
                continuation.yield(value)
            }
            observers.append(obs)
        }

        /// Register observer for auth failure notifications (uses object + userInfo, not JSON body).
        private func registerAuthObserver(center: DistributedNotificationCenter) {
            let obs = center.addObserver(
                forName: NSNotification.Name(DefaultSettings.Notifications.authFailure),
                object: nil,
                queue: nil
            ) { [authFailureContinuation] notification in
                let domainId = (notification.object as? String) ?? ""
                let reason = (notification.userInfo?["reason"] as? String) ?? "unknown"
                authFailureContinuation.yield(IPCAuthFailure(domainId: domainId, reason: reason))
            }
            observers.append(obs)
        }

        /// Register observer for extension init failure notifications.
        private func registerExtInitObserver(center: DistributedNotificationCenter) {
            let obs = center.addObserver(
                forName: NSNotification.Name(DefaultSettings.Notifications.extensionInitFailed),
                object: nil,
                queue: nil
            ) { [extensionInitFailureContinuation] notification in
                let domainId = (notification.object as? String) ?? ""
                let reason = (notification.userInfo?["reason"] as? String) ?? "unknown"
                extensionInitFailureContinuation.yield(
                    IPCExtensionInitFailure(domainId: domainId, reason: reason)
                )
            }
            observers.append(obs)
        }

        /// Encode a value to JSON and post it via `DistributedNotificationCenter`.
        private func postJSON(_ value: some Encodable, notificationName: NSNotification.Name) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            guard let string = String(data: data, encoding: .utf8) else { return }

            DistributedNotificationCenter.default()
                .post(Notification(name: notificationName, object: string))
        }
    }
#endif
