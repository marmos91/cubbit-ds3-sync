import SwiftUI

struct TrayMenuFooterView: View {
    var status: String
    var version: String
    var build: String

    var body: some View {
        HStack {
            Text(status)
                .font(DS3Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            Text("Version \(version) (\(build))")
                .font(DS3Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .background(.bar)
        .frame(height: 32)
    }
}

#Preview {
    TrayMenuFooterView(
        status: "Idle",
        version: "1.0.0",
        build: "1"
    )
}
