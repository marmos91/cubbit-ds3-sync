import Foundation
import FileProvider
import SwiftUI
import os.log

/// Manages a drive
@Observable class DS3DriveViewModel {
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "DriveViewModel")
    
    var drive: DS3Drive
    
    init(drive: DS3Drive) {
        self.drive = drive
    }
    
    /// Formats the drive's sync anchor. If the prefix is defined, it will be added to the project name
    /// - Returns: the drive's sync anchor string
    func syncAnchorString() -> String {
        var name = self.drive.syncAnchor.project.name
        
        if let prefix = self.drive.syncAnchor.prefix{
            name += "/\(prefix)"
        }
        
        return name
    }
    
    /// Returns the Cubbit's Web Console URL
    /// - Returns: the console url
    func consoleURL() -> URL? {
        var url =  "\(ConsoleURLs.projectsURL)/\(self.drive.syncAnchor.project.id)/buckets/\(self.drive.syncAnchor.bucket.name)"
        
        if let prefix = self.drive.syncAnchor.prefix {
            url += "/\(prefix)"
        }
        
        return URL(string: url)
    }
    
    /// Opens finder at the drive root
    func openFinder() async throws {
        try await self.drive.openFinder()
    }
    
    func reEnumerate() async throws {
        try await self.drive.reEnumerate()
    }
    
    func disconnect() async throws {
        try await self.drive.disconnect()
    }
}
