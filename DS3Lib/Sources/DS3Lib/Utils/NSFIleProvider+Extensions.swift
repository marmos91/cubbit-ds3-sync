import Foundation
import FileProvider

/// Codable payload stored inside `NSFileProviderSyncAnchor.rawValue`.
public struct SyncAnchorPayload: Codable, Sendable {
    public let date: Date
    public let reconciliationId: UUID
    public let itemCount: Int

    // swiftlint:disable:next force_unwrapping
    public static let nilReconciliationId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init(date: Date = Date(), reconciliationId: UUID = UUID(), itemCount: Int = 0) {
        self.date = date
        self.reconciliationId = reconciliationId
        self.itemCount = itemCount
    }

    public func toData() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func from(data: Data) -> SyncAnchorPayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncAnchorPayload.self, from: data)
    }
}

public extension NSFileProviderSyncAnchor {
    init(_ payload: SyncAnchorPayload) {
        self.init(rawValue: payload.toData())
    }

    init(_ date: Date) {
        self.init(SyncAnchorPayload(date: date))
    }

    /// Decodes the payload, falling back to legacy raw-binary Date format.
    /// Returns a `.distantPast` payload for unrecognized formats to trigger full re-enumeration.
    func toPayload() -> SyncAnchorPayload {
        if let payload = SyncAnchorPayload.from(data: self.rawValue) {
            return payload
        }

        if self.rawValue.count == MemoryLayout<Date>.size {
            var date = Date()
            _ = withUnsafeMutableBytes(of: &date) { ptr in
                self.rawValue.copyBytes(to: ptr)
            }
            return SyncAnchorPayload(date: date, reconciliationId: SyncAnchorPayload.nilReconciliationId)
        }

        return SyncAnchorPayload(date: .distantPast, reconciliationId: SyncAnchorPayload.nilReconciliationId)
    }

    func toDate() -> Date {
        toPayload().date
    }
}

// Extend NSFileProviderPage to handle S3 continuation tokens
public extension NSFileProviderPage {
    init(_ continuationToken: String) {
        if let data = continuationToken.data(using: .utf8) {
            self.init(rawValue: data)
        } else {
            self.init(rawValue: Data())
        }
    }

    func toContinuationToken() -> String? {
        if self == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage ||
            self == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage {
            return nil
        }

        // Convert Data to String
        if let retString = String(data: self.rawValue, encoding: .utf8), !retString.isEmpty {
            return retString
        } else {
            return nil
        }
    }
}
