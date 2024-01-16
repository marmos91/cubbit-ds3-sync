import SwiftUI

struct ProjectSelectionFooter: View {
    @Environment(ProjectSelectionViewModel.self) var projectSelectionViewModel: ProjectSelectionViewModel
    
    var onContinue: (() -> Void)?
    
    var body: some View {
        HStack {
            Spacer()
            Button(NSLocalizedString("Continue", comment: "Continue button")) {
                onContinue?()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(buttonDisabled())
            .frame(maxWidth: 95, maxHeight: 32, alignment: .trailing)
            .padding()
        }
        .background(Color(.sidebarBackground))
        .overlay(
            Rectangle().frame(
                width: nil,
                height: 1,
                alignment: .top
            )
            .foregroundColor(Color(.textFieldBorder)), alignment: .top)
    }
    
    func buttonDisabled() -> Bool {
        return self.projectSelectionViewModel.selectedProject == nil
    }
    
    func onContinue(perform action: @escaping () -> Void) -> ProjectSelectionFooter {
        var modifiedView = self
        modifiedView.onContinue = action
        return modifiedView
    }
}

#Preview {
    ProjectSelectionFooter()
        .environment(
            ProjectSelectionViewModel(
                authentication: DS3Authentication()
            )
        )
}
