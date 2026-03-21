import SwiftUI
import DS3Lib

struct ProjectSelectorErrorView: View {
    @Environment(ProjectSelectionViewModel.self) var projectSelectionViewModel: ProjectSelectionViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 16.0) {
                Image(.warningIcon)
                
                if projectSelectionViewModel.authenticationError != nil {
                    Text(projectSelectionViewModel.authenticationError?.localizedDescription ?? "No error")
                        .font(DS3Typography.body)
                        .multilineTextAlignment(.center)
                    
                    Button("Logout") {
                        projectSelectionViewModel.authentication.logout()
                    }
                    .pointingHandCursor()
                }
                if projectSelectionViewModel.error != nil {
                    Text(projectSelectionViewModel.error?.localizedDescription ?? "No error")
                        .font(DS3Typography.body)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        let viewModel = projectSelectionViewModel
                        Task {
                            await viewModel.loadProjects()
                        }
                    }
                    .pointingHandCursor()
                }
            }
            .padding()
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.errorBorder), lineWidth: 1)
            }
            
            Spacer()
        }
    }
}

#Preview {
    ProjectSelectorErrorView()
        .environment(
            ProjectSelectionViewModel(
               authentication: DS3Authentication(),
               projects: [
                    PreviewData.project,
                    PreviewData.secondProject
               ]
           )
        )
        .padding()
}
