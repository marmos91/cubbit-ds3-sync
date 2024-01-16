import SwiftUI

struct ProjectSelectionSidebar: View {
    var body: some View {
        ZStack {
            Color(.sidebarBackground)
                .ignoresSafeArea()
            
            VStack(alignment: .leading) {
                Text("Sync folder")
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.bold)
                    .padding(.bottom, 5.0)
                
                Text("Lorem Ipsum is simply dummy text of the printing and typesetting industry. Lorem Ipsum has been the industry's standard dummy text ever since the 1500s")
                    .font(.custom("Nunito", size: 14))
            }
            .padding()
            .padding(.horizontal, 5.0)
        }
        .frame(width: 240)
    }
}

#Preview {
    ProjectSelectionSidebar().padding()
}
