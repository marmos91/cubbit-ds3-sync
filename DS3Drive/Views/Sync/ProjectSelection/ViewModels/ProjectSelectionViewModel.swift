import Foundation
import SwiftUI
import os.log
import DS3Lib

@Observable class ProjectSelectionViewModel {
    private let logger: Logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    
    var authentication: DS3Authentication
    var ds3SDK: DS3SDK
    
    var projects: [Project] = []
    var loading: Bool = true
    var error: Error?
    var authenticationError: Error?
    var selectedProject: Project?
    
    init(authentication: DS3Authentication, projects: [Project] = []) {
        self.authentication = authentication
        self.ds3SDK = DS3SDK(withAuthentication: authentication)
        self.projects = projects
    }
    
    /// Load projects from IAM service
    /// - Parameter authentication: authentication library to use to authenticate
    @MainActor
    func loadProjects() async {
        self.loading = true
        defer { self.loading = false }
        
        do {
            // NOTE: Slow it down a little to improve UX
            try await Task.sleep(for: .seconds(0.5))
            self.projects = try await self.ds3SDK.getRemoteProjects()
        } catch let error as DS3AuthenticationError {
            self.logger.error("An authentication error occurred while loading projects: \(error)")
            self.authenticationError = error
        } catch {
            self.logger.error("An error occurred while loading projects: \(error)")
            self.error = error
        }
    }
    
    /// Selects the project to display in the sync setup, given its ID
    func selectProject(project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            selectedProject = projects[index]
        }
    }
}
