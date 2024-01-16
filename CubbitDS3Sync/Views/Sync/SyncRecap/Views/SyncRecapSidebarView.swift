import SwiftUI

struct SyncRecapSidebarView: View {
    var body: some View {
        ZStack {
            Color(.sidebarBackground)
                .ignoresSafeArea()
            
            VStack(alignment: .leading) {
                Text("Recap: confirm your information to create your drive")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.bold)
                    .padding(.bottom, 10)
                
                Text("Select role & bucket or folder..... utilizza la Cubbit Console per creare o gestire i tuoi progetti.")
                    .font(.custom("Nunito", size: 14))
                
            }
            .padding(20.0)
        }
        .border(width: 1, edges: [.trailing], color: .textFieldBorder)
        .frame(width: 240)
    }
}

#Preview {
    SyncRecapSidebarView()
}
