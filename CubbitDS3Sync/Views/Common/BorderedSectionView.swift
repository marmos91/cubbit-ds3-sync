import SwiftUI

struct BorderedSectionView<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack {
            content
        }
        .padding()
        .padding(.horizontal)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.textFieldBorder, lineWidth: 1)
                .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    BorderedSectionView {
        VStack {
            Text("Hello")
            Text("World")
        }
    }
    .padding()
}
