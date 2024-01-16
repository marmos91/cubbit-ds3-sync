import SwiftUI

struct OutlineLink: View {
    var text: String
    var href: String
    
    @State var isHover: Bool = false
    
    var body: some View {
        Link(text, destination: URL(string: href)!)
            .font(.custom("Nunito", size: 14))
            .tint(.white)
            .padding()
            .frame(height: 32)
//            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: 32)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.textFieldBackground, lineWidth: 1)
                    .if(isHover) { view in
                        view.fill(.hover)
                    }
            )
            .onHover { hovering in
                isHover = hovering
            }
            .onChange(of: isHover) {
                DispatchQueue.main.async {
                    if isHover {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(.vertical)
    }
}

#Preview {
    OutlineLink(text: "Sign up", href: "https://console.cubbit.eu/signup").padding()
}
