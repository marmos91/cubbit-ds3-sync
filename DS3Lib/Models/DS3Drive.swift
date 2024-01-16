import Foundation

enum DS3DriveStatus: Codable, Hashable {
    case sync
    case pause
    case idle
    case error
}

struct DS3Drive: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var syncAnchor: SyncAnchor
    var status: DS3DriveStatus
    
    var description: String {
        return "DS3Drive(name=\(name), anchor=\(syncAnchor)"
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.name)
        hasher.combine(self.status)
    }
    
    static func == (lhs: DS3Drive, rhs: DS3Drive) -> Bool {
        lhs.id == rhs.id
    }
}
