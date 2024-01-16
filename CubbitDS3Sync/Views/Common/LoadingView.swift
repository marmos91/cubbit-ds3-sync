import SwiftUI

struct LoadingView: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.0, anchor: .center)
            Spacer()
        }
    }
}
