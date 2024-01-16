import SwiftUI

struct ProjectSelectionView: View {
    @State var projectSelectionViewModel: ProjectSelectionViewModel
    
    var onProjectSelected: ((Project) -> Void)?
    
    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ProjectSelectionSidebar()
                    
                    if projectSelectionViewModel.loading {
                        LoadingView()
                    } else {
                        ProjectSelectorView()
                            .environment(projectSelectionViewModel)
                    }
                }
                ProjectSelectionFooter()
                    .onContinue {
                        if projectSelectionViewModel.selectedProject != nil {
                            onProjectSelected?(projectSelectionViewModel.selectedProject!)
                        }
                    }
                    .environment(projectSelectionViewModel)
            }.task {
                do {
                    try await  projectSelectionViewModel.loadProjects()
                } catch {
                    // TODO: Handle error!
                }
            }
        }
    }
    
    init(projectSelectionViewModel: ProjectSelectionViewModel) {
        self.projectSelectionViewModel = projectSelectionViewModel
    }
    
    func onProjectSelected(perform action: @escaping (Project) -> Void) -> ProjectSelectionView {
        var modifiedView = self
        modifiedView.onProjectSelected = action
        return modifiedView
    }
}

#Preview {
    ProjectSelectionView(
        projectSelectionViewModel: ProjectSelectionViewModel(
            authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
        )
    ).frame(
        minWidth: 800,
        maxWidth: 800,
        minHeight: 480,
        maxHeight: 480
    )
}
