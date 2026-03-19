import SwiftUI

struct TrayMenuItem: View {
    var title: String
    var enabled = true
    var action: (() -> Void)?

    @State private var isHover: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(DS3Typography.body)
                .foregroundStyle(enabled ? .primary : .secondary)

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
        .frame(height: 40)
        .background {
            if isHover {
                Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
            } else {
                Color.clear
            }
        }
        .onTapGesture {
            if enabled {
                action?()
            }
        }
        .onHover { isHover in
            if enabled {
                self.isHover = isHover
            }
        }
        .pointingHandCursor()
    }
}

#Preview {
    TrayMenuItem(
        title: "Add new Drive",
        enabled: false
    )
}
