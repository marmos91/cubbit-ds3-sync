import SwiftUI

struct NoProjectsView: View {
    @Environment(ProjectSelectionViewModel.self) var projectSelectionViewModel: ProjectSelectionViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16.0) {
                Image(.infoIcon)
                
                Text("You haven't created any projects yet, create your project on [the console](https://console.cubbit.eu/) and then come back here to synchronize it.")
                    .font(.custom("Nunito", size: 14))
                    .multilineTextAlignment(.center)
                
                Button("Refresh") {
                    Task {
                        await self.projectSelectionViewModel.loadProjects()
                    }
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
    NoProjectsView()
        .environment(
            ProjectSelectionViewModel(
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
            )
        )
        .padding()
}
