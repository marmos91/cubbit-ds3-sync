import SwiftUI

struct TrayMenuItem: View {
    var title: String
    var enabled = true
    var action: (() -> Void)?
    
    @State var isHover: Bool = false
    
    var body: some View {
        HStack {
            Text(title)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(enabled ? .white : .darkWhite)
            
            Spacer()
        }
        .padding()
        .frame(height: 40)
        .background {
            Color(enabled && isHover ? .hover : .clear)
        }
        .onTapGesture {
            if enabled {
                action?()
            }
        }
        .onHover { isHover in
            self.isHover = isHover
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
    TrayMenuItem(
        title: "Add new Drive",
        enabled: false
    )
}
