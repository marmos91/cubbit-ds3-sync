import SwiftUI

struct OutlineLink: View {
    var text: String
    var href: String

    @State var isHover: Bool = false

    var body: some View {
        Link(text, destination: URL(string: href)!)
            .font(DS3Typography.body)
            .padding()
            .frame(height: 32)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .if(isHover) { view in
                        view.fill(Color(nsColor: .quaternaryLabelColor))
                    }
            )
            .onHover { hovering in
                isHover = hovering
            }
            .pointingHandCursor()
            .padding(.vertical)
    }
}

#Preview {
    OutlineLink(text: "Sign up", href: "https://console.cubbit.eu/signup").padding()
}
