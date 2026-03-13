import SwiftUI

struct SyncRecapSidebarView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                Text("Recap: confirm your information to create your drive")
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)

                Text("Choose a name for your drive. The name you choose will be displayed in the finder")
                    .font(DS3Typography.body)

            }
            .padding(20.0)
        }
        .border(width: 1, edges: [.trailing], color: Color(nsColor: .separatorColor))
        .frame(width: 240)
    }
}

#Preview {
    SyncRecapSidebarView()
}
