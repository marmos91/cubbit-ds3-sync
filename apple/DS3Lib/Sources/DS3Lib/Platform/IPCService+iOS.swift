#if os(iOS)
    import Foundation

    /// iOS implementation of ``IPCService`` that uses Darwin notifications for signaling
    /// and App Group shared container files for payload exchange.
    ///
    /// **Write path:** JSON-encode payload -> write to temp file -> atomic rename to target.
    /// **Read path:** Darwin notification fires -> read & decode target file -> yield to stream.
    /// **Safety net:** A 30-second polling fallback reads all IPC files periodically in case
    /// Darwin notifications are missed (e.g. when the process is suspended by the system).
    final class IOSIPCService: IPCService, @unchecked Sendable {
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

        // MARK: - IPC Directory

        /// Directory within the App Group container used for IPC payload files.
        private let ipcDirectory: URL

        /// Active listener tasks (cancelled on stopListening).
        private var listenerTasks: [Task<Void, Never>] = []

        /// Tracks file modification dates to avoid re-delivering duplicate messages during polling.
        private var lastPolledModTimes: [String: Date] = [:]

        // MARK: - IPC File Names

        private enum IPCFile {
            static let statusChange = "statusChange.json"
            static let transferStats = "transferStats.json"
            static let command = "command.json"
            static let conflict = "conflict.json"
            static let authFailure = "authFailure.json"
            static let extensionInitFailure = "extensionInitFailure.json"
        }

        // MARK: - Init

        init() {
            // Resolve IPC directory in the App Group shared container
            guard let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)
            else {
                fatalError(
                    "App Group '\(DefaultSettings.appGroup)' not accessible. Check entitlements and provisioning profile."
                )
            }
            self.ipcDirectory = containerURL.appendingPathComponent("ipc", isDirectory: true)

            // Create directory if needed
            try? FileManager.default.createDirectory(
                at: ipcDirectory,
                withIntermediateDirectories: true
            )

            // Build all stream/continuation pairs
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
            let decoder = JSONDecoder()

            registerListener(
                named: DefaultSettings.Notifications.driveStatusChanged,
                file: IPCFile.statusChange,
                decoder: decoder,
                continuation: statusContinuation
            )
            registerListener(
                named: DefaultSettings.Notifications.driveTransferStats,
                file: IPCFile.transferStats,
                decoder: decoder,
                continuation: transferContinuation
            )
            registerListener(
                named: DefaultSettings.Notifications.command,
                file: IPCFile.command,
                decoder: decoder,
                continuation: commandContinuation
            )
            registerListener(
                named: DefaultSettings.Notifications.conflictDetected,
                file: IPCFile.conflict,
                decoder: decoder,
                continuation: conflictContinuation
            )
            registerListener(
                named: DefaultSettings.Notifications.authFailure,
                file: IPCFile.authFailure,
                decoder: decoder,
                continuation: authFailureContinuation
            )
            registerListener(
                named: DefaultSettings.Notifications.extensionInitFailed,
                file: IPCFile.extensionInitFailure,
                decoder: decoder,
                continuation: extensionInitFailureContinuation
            )

            // Polling fallback (~30s) as safety net for missed Darwin notifications
            let pollingTask = Task { [pollAllFiles, decoder] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    pollAllFiles(decoder)
                }
            }
            listenerTasks.append(pollingTask)
        }

        func stopListening() async {
            for task in listenerTasks {
                task.cancel()
            }
            listenerTasks.removeAll()

            statusContinuation.finish()
            transferContinuation.finish()
            commandContinuation.finish()
            conflictContinuation.finish()
            authFailureContinuation.finish()
            extensionInitFailureContinuation.finish()
        }

        // MARK: - Post methods

        func postStatusChange(_ change: DS3DriveStatusChange) async {
            writeAtomically(change, toFile: IPCFile.statusChange)
            DarwinNotificationCenter.shared.post(name: DefaultSettings.Notifications.driveStatusChanged)
        }

        func postTransferStats(_ stats: DriveTransferStats) async {
            writeAtomically(stats, toFile: IPCFile.transferStats)
            DarwinNotificationCenter.shared.post(name: DefaultSettings.Notifications.driveTransferStats)
        }

        func postCommand(_ command: IPCCommand) async {
            writeAtomically(command, toFile: IPCFile.command)
            DarwinNotificationCenter.shared.post(name: DefaultSettings.Notifications.command)
        }

        func postConflict(_ info: ConflictInfo) async {
            writeAtomically(info, toFile: IPCFile.conflict)
            DarwinNotificationCenter.shared.post(name: DefaultSettings.Notifications.conflictDetected)
        }

        func postAuthFailure(domainId: String, reason: String) async {
            let payload = IPCAuthFailure(domainId: domainId, reason: reason)
            writeAtomically(payload, toFile: IPCFile.authFailure)
            DarwinNotificationCenter.shared.post(name: DefaultSettings.Notifications.authFailure)
        }

        func postExtensionInitFailure(domainId: String, reason: String) async {
            let payload = IPCExtensionInitFailure(domainId: domainId, reason: reason)
            writeAtomically(payload, toFile: IPCFile.extensionInitFailure)
            DarwinNotificationCenter.shared.post(name: DefaultSettings.Notifications.extensionInitFailed)
        }

        // MARK: - Private helpers

        /// Register a Darwin notification listener that reads and decodes the corresponding IPC file.
        private func registerListener<T: Decodable & Sendable>(
            named notificationName: String,
            file filename: String,
            decoder: JSONDecoder,
            continuation: AsyncStream<T>.Continuation
        ) {
            let task = Task { [ipcDirectory] in
                let stream = DarwinNotificationCenter.shared.notifications(named: notificationName)
                for await _ in stream {
                    let fileURL = ipcDirectory.appendingPathComponent(filename)
                    guard let data = try? Data(contentsOf: fileURL) else { continue }
                    guard let value = try? decoder.decode(T.self, from: data) else { continue }
                    continuation.yield(value)
                }
            }
            listenerTasks.append(task)
        }

        /// Write a value atomically: encode to temp file, then rename to target.
        private func writeAtomically(_ value: some Encodable, toFile filename: String) {
            let targetURL = ipcDirectory.appendingPathComponent(filename)
            let tmpURL = ipcDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            guard let data = try? JSONEncoder().encode(value) else { return }
            do {
                try data.write(to: tmpURL)
                _ = try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.moveItem(at: tmpURL, to: targetURL)
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        /// Read all IPC files and yield any successfully decoded values.
        /// Used by the polling fallback to catch any missed notifications.
        private func pollAllFiles(decoder: JSONDecoder) {
            readAndYield(file: IPCFile.statusChange, decoder: decoder, continuation: statusContinuation)
            readAndYield(file: IPCFile.transferStats, decoder: decoder, continuation: transferContinuation)
            readAndYield(file: IPCFile.command, decoder: decoder, continuation: commandContinuation)
            readAndYield(file: IPCFile.conflict, decoder: decoder, continuation: conflictContinuation)
            readAndYield(file: IPCFile.authFailure, decoder: decoder, continuation: authFailureContinuation)
            readAndYield(
                file: IPCFile.extensionInitFailure,
                decoder: decoder,
                continuation: extensionInitFailureContinuation
            )
        }

        /// Read a single IPC file and yield the decoded value to the given continuation.
        /// Skips files whose modification date hasn't changed since the last poll.
        private func readAndYield<T: Decodable & Sendable>(
            file filename: String,
            decoder: JSONDecoder,
            continuation: AsyncStream<T>.Continuation
        ) {
            let url = ipcDirectory.appendingPathComponent(filename)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date
            else { return }

            if let lastMod = lastPolledModTimes[filename], modDate <= lastMod {
                return
            }

            guard let data = try? Data(contentsOf: url) else { return }
            guard let value = try? decoder.decode(T.self, from: data) else { return }
            lastPolledModTimes[filename] = modDate
            continuation.yield(value)
        }
    }
#endif
