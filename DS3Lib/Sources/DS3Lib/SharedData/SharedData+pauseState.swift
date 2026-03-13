import Foundation

extension SharedData {
    /// Persist the pause state for a specific drive.
    /// - Parameters:
    ///   - driveId: The UUID of the drive.
    ///   - paused: Whether the drive should be paused.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func setDrivePaused(_ driveId: UUID, paused: Bool) throws {
        let pauseURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.pauseStateFileName)

        var state = (try? loadPauseStateFromFile(at: pauseURL)) ?? [:]

        if paused {
            state[driveId.uuidString] = true
        } else {
            state.removeValue(forKey: driveId.uuidString)
        }

        let data = try JSONEncoder().encode(state)
        try coordinatedWrite(data: data, to: pauseURL)
    }

    /// Check whether a specific drive is paused.
    /// - Parameter driveId: The UUID of the drive.
    /// - Returns: `true` if the drive is paused, `false` otherwise (including when no file exists).
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func isDrivePaused(_ driveId: UUID) throws -> Bool {
        let state = try loadPauseState()
        return state[driveId] ?? false
    }

    /// Load the full pause state dictionary.
    /// - Returns: A dictionary mapping drive UUIDs to their pause status.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func loadPauseState() throws -> [UUID: Bool] {
        let pauseURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.pauseStateFileName)

        guard let stringState = try? loadPauseStateFromFile(at: pauseURL) else {
            return [:]
        }

        var result: [UUID: Bool] = [:]
        for (key, value) in stringState {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        return result
    }

    /// Internal helper to load the raw String-keyed pause state from a file URL.
    private func loadPauseStateFromFile(at url: URL) throws -> [String: Bool] {
        return try coordinatedRead(from: url) { data in
            try JSONDecoder().decode([String: Bool].self, from: data)
        }
    }
}
