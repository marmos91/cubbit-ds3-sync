import SwiftUI

@main
struct DS3DriveStubApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                Text("DS3 Drive")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Open the Files app to browse your DS3 drives.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding()
        }
    }
}
