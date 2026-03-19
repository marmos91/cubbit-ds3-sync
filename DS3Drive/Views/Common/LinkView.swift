import SwiftUI

struct LinkView: View {
    var text: String
    var href: String

    @State var isHover: Bool = false

    var body: some View {
        Link(text, destination: URL(string: href)!)
            .font(DS3Typography.body)
            .underline()
            .tint(isHover ? Color.accentColor.opacity(0.8) : Color.accentColor)
            .onHover { hovering in
                isHover = hovering
            }
            .pointingHandCursor()

    }
}

#Preview {
    LinkView(text: "Go to Cubbit", href: "https://cubbit.io")
        .padding()
}
