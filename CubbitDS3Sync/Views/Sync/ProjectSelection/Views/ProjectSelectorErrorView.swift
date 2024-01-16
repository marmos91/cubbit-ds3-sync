import SwiftUI

struct ProjectSelectorErrorView: View {
    var error: Error
    var onRetry: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16.0) {
                Image(.warningIcon)
                
                Text(error.localizedDescription)
                    .font(.custom("Nunito", size: 14))
                    .multilineTextAlignment(.center)
                    .font(.custom("Nunito", size: 14))
                
                Button(NSLocalizedString("Retry", comment: "Retry")) {
                    onRetry?()
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
    
    func onRetry(perform action: @escaping () -> Void) -> ProjectSelectorErrorView {
        var modifiedView = self
        modifiedView.onRetry = action
        return modifiedView
    }
}

#Preview {
    ProjectSelectorErrorView(
        error: NSError(
            domain: "io.cubbit.ds3Sync",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "This is an error message"
            ]
        )
    ).padding()
}
