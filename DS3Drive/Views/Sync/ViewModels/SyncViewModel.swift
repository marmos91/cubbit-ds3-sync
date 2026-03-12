import SwiftUI
import SotoS3
import DS3Lib

enum SyncSetupStep {
    case projectSelection
    case anchorSelection
    case driveNameSelection
}

@Observable class SyncSetupViewModel {
    var selectedProject: Project?
    var selectedSyncAnchor: SyncAnchor?
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
    
    func reset() {
        self.selectedProject = nil
        self.selectedSyncAnchor = nil
        self.setupStep = .projectSelection
    }
}
