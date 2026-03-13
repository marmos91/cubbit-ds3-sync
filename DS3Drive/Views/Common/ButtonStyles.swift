import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @State var isHover: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS3Typography.body)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isEnabled ?
                        (configuration.isPressed || isHover) ? Color.accentColor.opacity(0.8) : Color.accentColor :
                        Color(nsColor: .controlBackgroundColor)
                    )
            )
            .foregroundStyle(.white)
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
                view.foregroundStyle(.secondary)
            }
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @State var isHover: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS3Typography.body)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isEnabled ?
                          (configuration.isPressed || isHover) ? Color(nsColor: .separatorColor) : Color(.clear) :
                          Color(nsColor: .controlBackgroundColor)
                    )
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)

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
                view.foregroundStyle(.secondary)
            }
    }
}
