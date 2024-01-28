import Foundation
import SwiftUI

enum DS3DriveStatus: String, Codable, Hashable {
    case sync
    case indexing
    case idle
    case error
}

struct DS3DriveStats: Codable {
    var lastUpdate: Date
    var currentSpeedBs: Double? // Bytes per second
    
    func toString() -> String {
        if let currentSpeedBs = self.currentSpeedBs {
            let kilobyte = 1024.0
            let megabyte = kilobyte * kilobyte

            if currentSpeedBs >= megabyte {
                // Format speed in MB/s
                return String(format: "%.2f MB/s", currentSpeedBs / megabyte)
            } else {
                // Format speed in KB/s
                return String(format: "%.2f KB/s", currentSpeedBs / kilobyte)
            }
        } else {
            // Calculate time difference
            let timeDifference = Calendar.current.dateComponents([.minute, .hour], from: self.lastUpdate, to: Date())

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
}

@Observable class DS3Drive: Codable, Identifiable, Hashable {
    let id: UUID
    let syncAnchor: SyncAnchor
    var name: String
    
    init(
        id: UUID,
        name: String,
        syncAnchor: SyncAnchor
    ) {
        self.id = id
        self.name = name
        self.syncAnchor = syncAnchor
    }
    
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case syncAnchor
        case status
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
