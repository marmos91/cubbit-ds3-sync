import DS3Lib
import SwiftUI

/// Shared rounded-square project badge used across the wizard flow.
///
/// Renders the project's first letter inside a brand-coloured rounded
/// square (corner radius scales with size, ~25% of the side). The fill
/// color is deterministically derived from the project identifier via
/// `DS3Colors.colorForProject(_:)`. A single component is used by both
/// `TreeNavigationView` and `DriveConfirmView` — closes Plan 05-18 Gap 22.
///
/// Iteration after user feedback: switched from a flat circle to a
/// rounded square because the circular avatar pattern read as
/// "person/team" rather than "project / app icon". Rounded squares are
/// the macOS-native shape for software identity (Dock icons, app
/// thumbnails) and feel more meaningful for projects.
struct ProjectBadge: View {
    let projectId: String
    let projectName: String
    var size: CGFloat = 24

    var body: some View {
        Text(initial)
            .font(.custom("Figtree-SemiBold", size: size * 0.5))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(DS3Colors.colorForProject(projectId))
            )
    }

    private var initial: String {
        String(projectName.prefix(1).uppercased())
    }
}

#Preview {
    HStack(spacing: 12) {
        ProjectBadge(projectId: "a", projectName: "Alpha", size: 24)
        ProjectBadge(projectId: "b", projectName: "Bravo", size: 32)
        ProjectBadge(projectId: "c", projectName: "Charlie", size: 48)
    }
    .padding()
    .background(Color.black)
}
