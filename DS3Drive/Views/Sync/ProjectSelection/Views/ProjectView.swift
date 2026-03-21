import SwiftUI
import DS3Lib

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
                Text(project.name).font(DS3Typography.headline)
                Spacer()
            }
            .frame(maxWidth: 400)
            .padding()
            .onHover { hovering in
                self.isHover = hovering
            }
            .pointingHandCursor()
            .onTapGesture {
                onProjectSelected?(project)
            }
            .background {
                if isHover || isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor)
                        .fill(Color.accentColor.opacity(0.1))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
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
        project: PreviewData.project,
        isSelected: false
    )
    .padding()
}
