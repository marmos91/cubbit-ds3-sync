import SwiftUI
import DS3Lib

struct ProjectSelectorView: View {
    @Environment(ProjectSelectionViewModel.self) var projectSelectionViewModel: ProjectSelectionViewModel
    
    var body: some View {
        if self.shouldDisplayError() {
            ProjectSelectorErrorView()
                .environment(projectSelectionViewModel)
        } else {
            if projectSelectionViewModel.projects.isEmpty {
                NoProjectsView()
                    .environment(projectSelectionViewModel)
                    .padding(100.0)
            } else {
                ScrollView(showsIndicators: false) {
                    ForEach(projectSelectionViewModel.projects) { project in
                        ProjectView(
                            project: project,
                            isSelected: project.id == projectSelectionViewModel.selectedProject?.id
                        )
                        .onProjectSelected { project in
                            projectSelectionViewModel.selectProject(project: project)
                        }
                        .listRowSeparator(.hidden, edges: [.bottom])
                        .padding(.vertical, 7.0)
                    }
                }
                .padding(30.0)
            }
        }
    }
    
    func shouldDisplayError() -> Bool {
        return projectSelectionViewModel.error != nil || projectSelectionViewModel.authenticationError != nil
    }
}

#Preview {
   ProjectSelectorView()
       .environment(
            ProjectSelectionViewModel(
               authentication: DS3Authentication(),
               projects: [
                    PreviewData.project,
                    PreviewData.secondProject
               ]
           )
       )
}
