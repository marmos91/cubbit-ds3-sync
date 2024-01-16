import SwiftUI

struct TrayMenuFooterView: View {
    var version: String
    
    var body: some View {
        ZStack {
            Color(.sidebarBackground)
                .ignoresSafeArea()
            
            HStack {
                Spacer()
                
                Text("Version \(version)")
                    .font(.custom("Nunito", size: 12))
                    .foregroundStyle(Color(.darkWhite))
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: 32)
    }
}
#Preview {
    TrayMenuFooterView(
        version: "1.0.0"
    )
}
