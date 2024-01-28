import Foundation
import FileProvider
import SwiftUI
import os.log

/// Manages a drive
@Observable class DS3DriveViewModel {
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "DriveViewModel")
    
    var drive: DS3Drive
    var driveStatus: DS3DriveStatus = .idle
    var driveStats: DS3DriveStats = DS3DriveStats(lastUpdate: Date())
    
    var totalTransferredSize: Int64 = 0
    var totalTransferDuration: TimeInterval = 0
    var transferStatsResetTimer: Timer?
    
    init(drive: DS3Drive) {
        self.drive = drive
        
        self.setupObserver()
    }
    
    deinit {
        DistributedNotificationCenter
            .default()
            .removeObserver(self)
    }
    
    /// Sets up the observer for the drive to listen for notifications from the extension
    private func setupObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(DS3DriveViewModel.driveStatusChanged),
            name: .driveStatusChanged,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(DS3DriveViewModel.transferSpeedReceived),
            name: .driveTransferStats,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    
    /// Updates drive stats when it receives a notification from the extension
    /// - Parameter notification: the notification
    @objc @MainActor
    private func transferSpeedReceived(_ notification: Notification) {
        guard
            let stringDriveStats = notification.object as? String,
            let driveTransferStats = try? JSONDecoder().decode(DriveTransferStats.self, from: Data(stringDriveStats.utf8)),
            driveTransferStats.driveId == self.drive.id // Only update if the notification is for this drive
        else { return }
        
        self.transferStatsResetTimer?.invalidate()
        self.totalTransferredSize += driveTransferStats.size
        self.totalTransferDuration += driveTransferStats.duration
        self.driveStats.currentSpeedBs = Double(driveTransferStats.size) / driveTransferStats.duration
        
        self.transferStatsResetTimer = Timer.scheduledTimer(withTimeInterval: DefaultSettings.Timer.driveStatsReset, repeats: false) { _ in
            self.totalTransferredSize = 0
            self.totalTransferDuration = 0
            self.driveStats.currentSpeedBs = nil
            self.driveStats.lastUpdate = Date()
        }
    }
    
    /// Updates drive status when it receives a notification from the extension
    /// - Parameter notification: the notification
    @objc @MainActor
    private func driveStatusChanged(_ notification: Notification) {
        guard
            let stringDrive = notification.object as? String,
            let updateDriveStatusNotification = try? JSONDecoder().decode(DS3DriveStatusChange.self, from: Data(stringDrive.utf8)),
            updateDriveStatusNotification.driveId == self.drive.id // Only update if the notification is for this drive
        else { return }
        
        self.driveStatus = updateDriveStatusNotification.status
    }
    
    /// Formats the drive's sync anchor. If the prefix is defined, it will be added to the project name
    /// - Returns: the drive's sync anchor string
    func syncAnchorString() -> String {
        var name = drive.syncAnchor.project.name
        
        if drive.syncAnchor.prefix != nil {
            name += "/\(drive.syncAnchor.prefix!)"
        }
        
        return name
    }
    
    /// Returns the Cubbit's Web Console URL
    /// - Returns: the console url
    func consoleURL() -> URL? {
        var url =  "\(ConsoleURLs.projectsURL)/\(drive.syncAnchor.project.id)/buckets/\(drive.syncAnchor.bucket.name)"
        
        if drive.syncAnchor.prefix != nil {
            url += "/\(drive.syncAnchor.prefix!)"
        }
        
        return URL(string: url)
    }
    
    /// Opens finder at the drive root
    func openFinder() async throws {
        let domain = self.fileProviderDomain()
        
        guard let url = try? await NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer) else { return }
            
        self.logger.debug("Opening finder at url \(url.path())")
        
        let _ = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        url.stopAccessingSecurityScopedResource()
    }
    
    /// Reenumerates the drive
    func reEnumerate() async throws {
        let domain = self.fileProviderDomain()
        
        self.logger.info("Reenumerating domain \(domain.displayName)")
        
        try await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
            
        self.logger.info("Enumerator signaled for domain \(domain.displayName)")
    }
    
    /// Returns the drive's file provider domain
    /// - Returns: the drive's file provider domain
    func fileProviderDomain() -> NSFileProviderDomain {
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: self.drive.id.uuidString
            ),
            displayName: self.drive.name
        )
    }
}
