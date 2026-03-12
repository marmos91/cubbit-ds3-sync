import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @State var isHover: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Nunito", size: 14))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isEnabled ?
                        (configuration.isPressed || isHover) ? Color(.buttonPrimaryColorHover) : Color(.buttonPrimary) :
                        Color(.darkMainTop)
                    )
            )
            .onHover {
                isHover = $0
            }
            .onChange(of: isHover) {
                DispatchQueue.main.async {
                    if isHover {
                        if !isEnabled {
                            NSCursor.operationNotAllowed.push()
                        } else {
                            NSCursor.pointingHand.push()
                        }
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .if(!isEnabled) { view in
                view.foregroundStyle(.disabledText)
            }
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @State var isHover: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Nunito", size: 14))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isEnabled ?
                          (configuration.isPressed || isHover) ? Color(.darkMainBorder) : Color(.clear) :
                          Color(.darkMainTop)
                    )
                    .stroke(Color(.darkMainBorder), lineWidth: 1)
                
            )
            .onHover { hovering in
                isHover = hovering
            }
            .onChange(of: isHover) {
                DispatchQueue.main.async {
                    if isHover {
                        if !isEnabled {
                            NSCursor.operationNotAllowed.push()
                        } else {
                            NSCursor.pointingHand.push()
                        }
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .if(!isEnabled) { view in
                view.foregroundStyle(.disabledText)
            }
    }
}
