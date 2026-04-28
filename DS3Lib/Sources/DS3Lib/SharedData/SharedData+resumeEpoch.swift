import Foundation

public extension SharedData {
    /// Reads the per-drive resume epoch.
    ///
    /// The epoch is bumped on every pause→resume transition and is folded into
    /// `S3Item.itemVersion.contentVersion` so Apple evicts its cached
    /// "no thumbnail" responses for items that returned nil during the pause
    /// window. This is a deliberate, narrow exception to D-14 ("contentVersion
    /// derived from sourceETag only") — the epoch only changes on explicit
    /// resume, never during steady-state operation, so the steady-state cache
    /// hit path is unaffected.
    ///
    /// - Parameter driveId: The UUID of the drive.
    /// - Returns: The current epoch (`0` if never resumed since first launch).
    func resumeEpoch(forDrive driveId: UUID) -> Int {
        (try? loadResumeEpochs())?[driveId] ?? 0
    }

    /// Increments the resume epoch for a drive. Call from the main app on
    /// pause→resume; the extension reads via `resumeEpoch(forDrive:)` from
    /// `S3Item.itemVersion`.
    /// - Parameter driveId: The UUID of the drive.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    @discardableResult
    func incrementResumeEpoch(forDrive driveId: UUID) throws -> Int {
        let url = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.resumeEpochFileName)

        var state: [String: Int] = (try? coordinatedRead(from: url) { data in
            try JSONDecoder().decode([String: Int].self, from: data)
        }) ?? [:]

        let next = (state[driveId.uuidString] ?? 0) + 1
        state[driveId.uuidString] = next

        let data = try JSONEncoder().encode(state)
        try coordinatedWrite(data: data, to: url)
        return next
    }

    /// Loads the full resume-epoch dictionary.
    /// - Returns: A dictionary mapping drive UUIDs to their current epoch.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    func loadResumeEpochs() throws -> [UUID: Int] {
        let url = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.resumeEpochFileName)
        let stringKeyed: [String: Int] = (try? coordinatedRead(from: url) { data in
            try JSONDecoder().decode([String: Int].self, from: data)
        }) ?? [:]

        var result: [UUID: Int] = [:]
        for (key, value) in stringKeyed {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        return result
    }
}
