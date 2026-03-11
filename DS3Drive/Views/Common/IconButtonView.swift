import SwiftUI

struct IconButtonView: View {
    var iconName: ImageResource
    var action: () -> Void
    
    @State var isHover: Bool = false
    
    var body: some View {
        Button {
            action()
        } label: {
            Image(iconName)
        }
        .frame(width: 32, height: 32)
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.darkMainTop, lineWidth: 1)
                .if(isHover) { view in
                    view.fill(.hover)
                }
        }
        .onHover { hovering in
            self.isHover = hovering
        }
        .onChange(of: isHover) {
            DispatchQueue.main.async {
                if self.isHover {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}

#Preview {
    IconButtonView(iconName: .arrowWestIcon) {
        
    }.padding()
}
