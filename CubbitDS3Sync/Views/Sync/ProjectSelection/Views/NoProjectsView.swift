import SwiftUI

struct NoProjectsView: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16.0) {
                Image(.infoIcon)
                
                Text("You haven't created any projects yet, create your project on [the console](https://console.cubbit.eu/) and then come back here to synchronize it.")
                    .font(.custom("Nunito", size: 14))
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
    NoProjectsView().padding()
}
