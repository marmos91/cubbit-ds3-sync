import SwiftUI
import DS3Lib

enum SyncSetupStep {
    case treeNavigation
    case driveConfirm
}

@Observable class SyncSetupViewModel {
    var selectedProject: Project?
    var selectedSyncAnchor: SyncAnchor?
    var selectedBucket: Bucket?
    var selectedPrefix: String?
    var setupStep: SyncSetupStep = .treeNavigation

    var suggestedDriveName: String {
        guard let bucket = selectedBucket else { return "" }

        if let prefix = selectedPrefix, !prefix.isEmpty {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lastComponent = trimmed.components(separatedBy: "/").last ?? trimmed
            return "\(bucket.name)/\(lastComponent)"
        }

        return bucket.name
    }

    func selectProject(project: Project) {
        self.selectedProject = project
    }

    func selectSyncAnchor(anchor: SyncAnchor) {
        self.selectedSyncAnchor = anchor
        self.selectedBucket = anchor.bucket
        self.selectedPrefix = anchor.prefix
        self.setupStep = .driveConfirm
    }

    func selectSyncSetupStep(_ step: SyncSetupStep) {
        self.setupStep = step
    }

    func goBack() {
        self.setupStep = .treeNavigation
    }

    func reset() {
        self.selectedProject = nil
        self.selectedSyncAnchor = nil
        self.selectedBucket = nil
        self.selectedPrefix = nil
        self.setupStep = .treeNavigation
    }
}
