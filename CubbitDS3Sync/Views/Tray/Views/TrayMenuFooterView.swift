import SwiftUI

struct TrayMenuFooterView: View {
    var status: String
    var version: String
    
    var body: some View {
        ZStack {
            Color(.darkMainStandard)
                .ignoresSafeArea()
            
            HStack {
                Text(status)
                    .font(.custom("Nunito", size: 12))
                    .foregroundStyle(Color(.darkWhite))
                    .padding(.horizontal)
                
                Spacer()
                
                Text("Version \(version)")
                    .font(.custom("Nunito", size: 12))
                    .foregroundStyle(Color(.darkWhite))
                    .padding(.horizontal)
            }
        }
        .frame(height: 32)
    }
}
#Preview {
    TrayMenuFooterView(
        status: "Idle",
        version: "1.0.0"
    )
}
