import Foundation
import SwiftUI

@Observable class ProjectSelectionViewModel {
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
            print("Loading DS3 projects")
            self.projects = try await self.ds3SDK.getRemoteProjects()
            print("\(self.projects.count) DS3 projects loaded")
        }
        catch DS3AuthenticationError.serverError {
            try self.authentication.logout()
        }
        catch {
            print("An error occurred while loading projects: \(error)")
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
