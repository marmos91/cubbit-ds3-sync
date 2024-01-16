import SwiftUI

struct LinkView: View {
    var text: String
    var href: String
    
    @State var isHover: Bool = false
    
    var body: some View {
        Link(text, destination: URL(string: href)!)
            .font(.custom("Nunito", size: 14))
            .underline()
            .tint(isHover ? Color(.buttonPrimaryColorHover) : Color(.buttonPrimary))
            .onHover(perform: { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
                
                isHover = hovering
            })
        
    }
}

#Preview {
    LinkView(text: "Go to Cubbit", href: "https://cubbit.io")
        .padding()
}
