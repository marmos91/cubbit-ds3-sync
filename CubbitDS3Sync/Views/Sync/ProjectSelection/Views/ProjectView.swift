import SwiftUI

struct ProjectView: View {
    var project: Project
    var isSelected: Bool
    var onProjectSelected: ((Project) -> Void)?

    @State var isHover: Bool = false
    
    var body: some View {
        HStack {
            Spacer()
            
            HStack {
                ProjectEmblemView(shortName: project.short())
                Text(project.name).font(.custom("Nunito", size: 16))
                Spacer()
            }
            .frame(maxWidth: 400)
            .padding()
            .onHover { hovering in
                self.isHover = hovering
            }
            .onChange(of: isHover) {
                DispatchQueue.main.async {
                    if self.isHover {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .onTapGesture {
                onProjectSelected?(project)
            }
            .background {
                if isHover || isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.buttonPrimary))
                        .fill(Color(.hover))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.textFieldBorder))
                }
            }
            
            Spacer()
        }
    }
    
    func onProjectSelected(perform action: @escaping (Project) -> Void) -> ProjectView {
        var modifiedView = self
        modifiedView.onProjectSelected = action
        return modifiedView
    }
}

#Preview {
    ProjectView(
        project: Project(
            id: UUID().uuidString,
            name: "Test",
            description: "Test project",
            email: "test@cubbit.io",
            createdAt: "2023-10-23",
            tenantId: UUID().uuidString,
            rootAccountEmail: "root@cubbit.io",
            users: [
                IAMUser(
                    id: UUID().uuidString,
                    username: "root",
                    isRoot: true
                )
            ]
        ),
        isSelected: false
    )
    .padding()
}
