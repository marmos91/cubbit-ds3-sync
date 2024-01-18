import Foundation
import SwiftUI
import os.log

@Observable class ProjectSelectionViewModel {
    private let logger: Logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync", category: "ProjectSelectionViewModel")
    
    var authentication: DS3Authentication
    var ds3SDK: DS3SDK
    
    var projects: [Project] = []
    var loading: Bool = true
    var error: Error? = nil
    var selectedProject: Project? = nil
    
    init(authentication: DS3Authentication, projects: [Project] = []) {
        self.authentication = authentication
        self.ds3SDK = DS3SDK(withAuthentication: authentication)
        self.projects = projects
    }
    
    /// Load projects from IAM service
    /// - Parameter authentication: authentication library to use to authenticate
    @MainActor
    func loadProjects() async throws {
        self.loading = true
        defer { self.loading = false }
        
        do {
            // NOTE: Slow it down a little to improve UX
            try await Task.sleep(for: .seconds(0.5))
            self.projects = try await self.ds3SDK.getRemoteProjects()
        }
        catch DS3AuthenticationError.serverError {
            try self.authentication.logout()
        }
        catch {
            self.logger.error("An error occurred while loading projects: \(error)")
            self.error = error
        }
}
    
    /// Selects the project to display in the sync setup, given its ID
    func selectProject(project: Project) {
        if let index = projects.firstIndex(where: {$0.id == project.id}) {
            selectedProject = projects[index]
        }
    }
}
