import SwiftUI

struct TrayMenuItem: View {
    var title: String
    var enabled = true
    var accent = false
    var action: (() -> Void)?

    @State private var isHover: Bool = false

    private var textColor: Color {
        if accent { return Color.accentColor }
        if enabled { return .primary }
        return .secondary
    }

    var body: some View {
        HStack {
            Text(title)
                .font(DS3Typography.body)
                .foregroundStyle(textColor)

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
        .frame(height: 40)
        .background(isHover ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear)
        .onTapGesture {
            guard enabled else { return }
            action?()
        }
        .onHover { isHover in
            guard enabled else { return }
            self.isHover = isHover
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
