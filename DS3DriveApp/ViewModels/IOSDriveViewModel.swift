#if os(iOS)
import SwiftUI
import DS3Lib

/// View model that provides per-drive real-time status and transfer speed
/// by consuming ``IPCService`` AsyncStreams.
@MainActor @Observable final class IOSDriveViewModel {

    // MARK: - Published state

    /// Maps drive ID to its current status
    var driveStatuses: [UUID: DS3DriveStatus] = [:]

    /// Maps drive ID to its current transfer speed in bytes/sec
    var driveTransferSpeeds: [UUID: Double] = [:]

    // MARK: - Private

    @ObservationIgnored
    private let ipcService: any IPCService

    @ObservationIgnored
    private var statusTask: Task<Void, Never>?

    @ObservationIgnored
    private var transferTask: Task<Void, Never>?

    // MARK: - Init

    init(ipcService: any IPCService) {
        self.ipcService = ipcService
    }

    // MARK: - Lifecycle

    func startListening() {
        Task {
            await ipcService.startListening()
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            for await change in self.ipcService.statusUpdates {
                self.driveStatuses[change.driveId] = change.status
            }
        }

        transferTask = Task { [weak self] in
            guard let self else { return }
            for await stats in self.ipcService.transferSpeeds {
                if stats.duration > 0 {
                    self.driveTransferSpeeds[stats.driveId] = Double(stats.size) / stats.duration
                } else {
                    self.driveTransferSpeeds[stats.driveId] = nil
                }
            }
        }
    }

    func stopListening() {
        statusTask?.cancel()
        statusTask = nil
        transferTask?.cancel()
        transferTask = nil

        Task {
            await ipcService.stopListening()
        }
    }

    // MARK: - Accessors

    func status(for driveId: UUID) -> DS3DriveStatus {
        driveStatuses[driveId] ?? .idle
    }

    func speed(for driveId: UUID) -> Double? {
        driveTransferSpeeds[driveId]
    }

    // MARK: - Display helpers

    static func statusLabel(for status: DS3DriveStatus) -> String {
        switch status {
        case .idle: "Synced"
        case .sync: "Syncing"
        case .indexing: "Indexing"
        case .error: "Error"
        case .paused: "Paused"
        }
    }

    static func statusColor(for status: DS3DriveStatus) -> Color {
        switch status {
        case .idle: IOSColors.statusSynced
        case .sync, .indexing: IOSColors.statusSyncing
        case .error: IOSColors.statusError
        case .paused: IOSColors.statusPaused
        }
    }

    // MARK: - Commands

    func postCommand(_ command: IPCCommand) async {
        await ipcService.postCommand(command)
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        } else if bytesPerSecond >= 1024 {
            String(format: "%.1f KB/s", bytesPerSecond / 1024)
        } else {
            String(format: "%.0f B/s", bytesPerSecond)
        }
    }
}
#endif
