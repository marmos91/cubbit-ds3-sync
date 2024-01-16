import SwiftUI
import SotoS3

enum SyncSetupStep {
    case projectSelection
    case anchorSelection
    case driveNameSelection
}

@Observable class SyncSetupViewModel {
    var selectedProject: Project? = nil
    var selectedSyncAnchor: SyncAnchor? = nil
    var setupStep: SyncSetupStep = .projectSelection
    
    func selectProject(project: Project) {
        self.selectedProject = project
        self.selectSyncSetupStep(.anchorSelection)
    }
    
    func selectSyncAnchor(anchor: SyncAnchor) {
        self.selectedSyncAnchor = anchor
        self.selectSyncSetupStep(.driveNameSelection)
    }
    
    func selectSyncSetupStep(_ step: SyncSetupStep) {
        self.setupStep = step
    }
}
