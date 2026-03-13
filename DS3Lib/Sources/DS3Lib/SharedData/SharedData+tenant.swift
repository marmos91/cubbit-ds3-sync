import Foundation

extension SharedData {
    /// Persist the tenant name to the App Group shared container.
    /// - Parameter tenant: The tenant name to persist.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func persistTenantName(_ tenant: String) throws {
        let tenantURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        try coordinatedWriteString(tenant, to: tenantURL)
    }

    /// Load the persisted tenant name from the App Group shared container.
    /// - Returns: The persisted tenant name.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed,
    ///           or a file system error if the tenant file does not exist.
    public func loadTenantNameFromPersistence() throws -> String {
        let tenantURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        return try coordinatedReadString(from: tenantURL)
    }

    /// Delete the persisted tenant name from the App Group shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func deleteTenantNameFromPersistence() throws {
        let tenantURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.tenantFileName)
        try FileManager.default.removeItem(at: tenantURL)
    }

    /// Persist the coordinator URL to the App Group shared container.
    /// - Parameter coordinatorURL: The coordinator URL string to persist.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func persistCoordinatorURL(_ coordinatorURL: String) throws {
        let urlFileURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)
        try coordinatedWriteString(coordinatorURL, to: urlFileURL)
    }

    /// Load the persisted coordinator URL from the App Group shared container.
    /// - Returns: The persisted coordinator URL string.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed,
    ///           or a file system error if the coordinator URL file does not exist.
    public func loadCoordinatorURLFromPersistence() throws -> String {
        let urlFileURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)
        return try coordinatedReadString(from: urlFileURL)
    }

    /// Delete the persisted coordinator URL from the App Group shared container.
    /// - Throws: `SharedDataError.cannotAccessAppGroup` if the app group cannot be accessed.
    public func deleteCoordinatorURLFromPersistence() throws {
        let urlFileURL = try sharedContainerURL().appendingPathComponent(DefaultSettings.FileNames.coordinatorURLFileName)
        try FileManager.default.removeItem(at: urlFileURL)
    }
}
