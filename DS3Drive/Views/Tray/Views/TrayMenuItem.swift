import SwiftUI

struct TrayMenuItem: View {
    var title: String
    var systemImage: String?
    var enabled = true
    var accent = false
    var action: (() -> Void)?

    @State private var isHover: Bool = false

    private var textColor: Color {
        if accent { return DS3Colors.brandPrimary }
        if enabled { return DS3Colors.brandTextPrimary }
        return DS3Colors.brandTextSecondary
    }

    private var iconColor: Color {
        if accent { return DS3Colors.brandPrimary }
        return DS3Colors.brandTextSecondary
    }

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            // Leading SF Symbol column. Hierarchical rendering gives a
            // free two-tone Apple look; the fixed-width frame keeps the
            // text labels aligned even when symbols vary in width.
            if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
            }

            Text(title)
                .font(DS3Typography.body)
                .foregroundStyle(textColor)

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.md)
        .padding(.vertical, DS3Spacing.sm)
        .frame(height: 32)
        // Plan 05-18b iteration: brand-tinted hover spans the full row
        // width with no rounded corners. The previous inset rounded chip
        // looked floating; the user wants a flat highlight that fills
        // the row edge-to-edge.
        .frame(maxWidth: .infinity)
        .background(DS3Colors.brandPrimary.opacity(isHover ? 0.12 : 0))
        .animation(.easeOut(duration: 0.12), value: isHover)
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
