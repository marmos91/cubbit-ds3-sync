import Foundation
import SwiftUI

enum DS3DriveStatus: String, Codable, Hashable {
    case sync
    case pause
    case idle
    case error
}

struct DS3DriveStats: Codable {
    var lastUpdate: Date
    var currentSpeedMbs: Double?
}

@Observable class DS3Drive: Codable, Identifiable, Hashable {
    let id: UUID
    let syncAnchor: SyncAnchor
    var name: String
    
    var status: DS3DriveStatus
    var statsString: String {
        self.formatStatsString()
    }
    @ObservationIgnored
    private var stats: DS3DriveStats
    
    init(
        id: UUID,
        name: String,
        syncAnchor: SyncAnchor,
        status: DS3DriveStatus
    ) {
        self.id = id
        self.name = name
        self.syncAnchor = syncAnchor
        self.status = status
        self.stats = DS3DriveStats(lastUpdate: Date())
    }
    
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case syncAnchor
        case status
    }
    
    private func formatStatsString() -> String {
        if let currentSpeedMbs = self.stats.currentSpeedMbs {
            return String(format: "%.2f MB/s", currentSpeedMbs)
        } else {
            let timeDifference = Calendar.current.dateComponents(
                [.minute, .hour],
                from: self.stats.lastUpdate, 
                to: Date()
            )
            
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
        }
    }
    
    // MARK: - Equatable
    
    static func == (lhs: DS3Drive, rhs: DS3Drive) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = try container.decode(UUID.self, forKey: .id)
        self.syncAnchor = try container.decode(SyncAnchor.self, forKey: .syncAnchor)
        self.name = try container.decode(String.self, forKey: .name)
        self.status = try container.decode(DS3DriveStatus.self, forKey: .status)
        self.stats = DS3DriveStats(lastUpdate: Date())
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.syncAnchor, forKey: .syncAnchor)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.status, forKey: .status)
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
        hasher.combine(self.status)
    }
}
