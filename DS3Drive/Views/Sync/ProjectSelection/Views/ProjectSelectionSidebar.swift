import SwiftUI

struct ProjectSelectionSidebar: View {
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                Text("Select DS3 Project")
                    .font(DS3Typography.headline)
                    .fontWeight(.bold)
                    .padding(.bottom, 5.0)

                Text("Please select a DS3 Project to start. Inside your project you will select a Bucket to sync with your local drive")
                    .font(DS3Typography.body)
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
