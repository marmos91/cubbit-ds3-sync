import Foundation
import SwiftUI
import FileProvider
import os.log

/// The transfer direction
enum TransferDirection: String, Codable {
    case upload
    case download
}

enum DS3DriveStatus: String, Codable, Hashable {
    /// The drive is synchronizing (uploading or downloading)
    case sync
    
    /// The drive is indexing (scanning/listing files)
    case indexing
    
    /// The drive is idle. It is not performing any operation.
    case idle
    
    /// The drive is in an error state. The user should perform an action to fix the error.
    case error
}

/// A class representing a DS3Drive in the app. It is used to keep track of the synchronization state of a drive.
@Observable class DS3Drive: Codable, Identifiable, Hashable {
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.DS3Lib", category: "DS3Drive")
    
    /// An unique identifier for the drive
    let id: UUID
    
    /// The `SyncAnchor` of the drive.
    let syncAnchor: SyncAnchor
    
    /// The name of the drive. This name is displayed in the finder's sidebar (**only if more than one drive is created**).
    /// Drives' names should be unique.
    var name: String
    
    /// The status of the drive
    var status: DS3DriveStatus {
        guard
            let uploadProgress = self.uploadProgress,
            let downloadProgress = self.downloadProgress
        else {
            self.lastUpdate = Date()
            return .idle
        }
        
        if !uploadProgress.isFinished || !downloadProgress.isFinished {
            return .sync
        }
        
        self.lastUpdate = Date()
        return .idle
    }
    
    /// The global upload progress of the drive
    var uploadProgress: Progress?
    
    /// The global download progress of the drive
    var downloadProgress: Progress?
    
    /// The last time the drive was updated
    var lastUpdate: Date?
    
    var connected: Bool {
        return !self.fileProviderDomain().isDisconnected
    }
    
    var disconnected: Bool {
        return self.fileProviderDomain().isDisconnected
    }
    
    var hidden: Bool {
        return self.fileProviderDomain().isHidden
    }
    
    init(
        id: UUID,
        name: String,
        syncAnchor: SyncAnchor
    ) {
        self.id = id
        self.name = name
        self.syncAnchor = syncAnchor
        
        let fileProviderManager = NSFileProviderManager(for: self.fileProviderDomain())
        
        self.uploadProgress = fileProviderManager?.globalProgress(for: .uploading)
        self.downloadProgress = fileProviderManager?.globalProgress(for: .downloading)
    }
    
    func persist() throws {
        try SharedData.default().persistDS3Drive(ds3Drive: self)
    }
    
    // MARK: - File Provider
    
    /// Returns the drive's file provider domain
    /// - Returns: the drive's file provider domain
    func fileProviderDomain() -> NSFileProviderDomain {
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: self.id.uuidString
            ),
            displayName: self.name
        )
    }
    
    /// Reenumerates the drive
    func reEnumerate() async throws {
        let domain = self.fileProviderDomain()
        
        self.logger.info("Reenumerating domain \(domain.displayName)")
        
        try await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
            
        self.logger.info("Enumerator signaled for domain \(domain.displayName)")
    }
    
    /// Disconnect the drive and removes it
    func disconnect() async throws {
        self.logger.info("Disconnecting drive with id \(self.id)")
        try await NSFileProviderManager.remove(self.fileProviderDomain(), mode: .removeAll)
    }
    
    /// Opens the finder at the root of the drive
    func openFinder() async throws {
        let domain = self.fileProviderDomain()
        
        guard let url = try? await NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer) else { return }
            
        self.logger.debug("Opening finder at url \(url.path())")
        
        let _ = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        url.stopAccessingSecurityScopedResource()
    }
    
    // MARK: - Status
    
    /// Returns a status string representing the current status of the drive. If the drive is idle, it will return the time since the last update.
    /// If the drive is in an error state, it will return "Error". If the drive is synchronizing, it will return the progress of the synchronization.
    /// - Returns: the status string
    func statusString() -> String {
        switch self.status {
        case .idle:
            let lastUpdate = self.lastUpdate ?? Date()
            
            let timeDifference = Calendar.current.dateComponents([.minute, .hour], from: lastUpdate, to: Date())

            if let minutes = timeDifference.minute, minutes > 0 {
                // Display time in minutes ago
                return "Updated \(minutes) minute\(minutes == 1 ? "" : "s") ago"
            } else if let hours = timeDifference.hour, hours > 0 {
                // Display time in hours ago
                return "Updated \(hours) hour\(hours == 1 ? "" : "s") ago"
            } else {
                // If less than a minute, consider it as "just updated"
                return "Just Updated"
            }
        case .error:
            return "Error"
        default:
            return self.formatProgress()
        }
    }
    
    /// Formats the overall progress of the drive. It will return a string with the upload and download progress.
    /// - Returns: the progress string
    private func formatProgress() -> String {
        return self.formatProgress(
            self.uploadProgress, direction: .upload
        ).appending(
            self.formatProgress(self.downloadProgress, direction: .download)
        )
    }
    
    /// Formats a progress object into a string. It will return a string with the progress of the transfer.
    /// - Parameters:
    ///   - progress: the progress object
    ///   - direction: the direction of the transfer
    /// - Returns: the progress string
    private func formatProgress(_ progress: Progress?, direction: TransferDirection) -> String {
        guard let progress = progress else { return "" }
        
        var progressString = ""

        if !progress.isFinished {
            switch direction {
            case .upload:
                progressString.append("↑ ")
            case .download:
                progressString.append("↓ ")
            }

            let countFormat = ByteCountFormatter()
            countFormat.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
            countFormat.countStyle = .file
            countFormat.allowsNonnumericFormatting = false
            
            let completed = countFormat.string(fromByteCount: progress.completedUnitCount)
            let total = countFormat.string(fromByteCount: progress.totalUnitCount)
            var completion = String(format: "%@ / %@ %.2f%%", completed, total, progress.fractionCompleted * 100)
            
            if let total = progress.fileTotalCount, let completed = progress.fileCompletedCount {
                completion.append("  (\(completed) / \(total) files)")
            }

            progressString.append(completion)
        }
        
        return progressString
    }
    
    // MARK: - Equatable
    
    static func == (lhs: DS3Drive, rhs: DS3Drive) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case syncAnchor
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(UUID.self, forKey: .id)
        self.syncAnchor = try container.decode(SyncAnchor.self, forKey: .syncAnchor)
        self.name = try container.decode(String.self, forKey: .name)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.syncAnchor, forKey: .syncAnchor)
        try container.encode(self.name, forKey: .name)
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
    }
}
