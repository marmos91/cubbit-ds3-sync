import SwiftUI
import DS3Lib

/// Side panel showing recent files per drive, matching the Figma file status design.
/// Reads `driveViewModel.recentFiles` directly so @Observable triggers live updates.
struct RecentFilesPanel: View {
    let driveViewModel: DS3DriveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if driveViewModel.recentFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .padding(.vertical, DS3Spacing.sm)
    }

    // MARK: - File List

    @ViewBuilder
    private var fileList: some View {
        let sorted = driveViewModel.recentFiles.sorted { $0.status < $1.status }
        ForEach(sorted.prefix(10)) { entry in
            RecentFileRow(entry: entry, driveViewModel: driveViewModel)
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS3Spacing.sm) {
            Image(systemName: "doc")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(NSLocalizedString("No recent files", comment: "Empty recent files"))
                .font(DS3Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS3Spacing.xl)
    }
}

/// A single row in the recent files panel — Figma style with status icon, name, size + time.
private struct RecentFileRow: View {
    let entry: RecentFileEntry
    let driveViewModel: DS3DriveViewModel
    @State private var isHover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS3Spacing.md) {
                // Status icon
                Image(systemName: statusIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(statusColor)
                    .frame(width: 20, alignment: .center)

                // File info
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.filename)
                        .font(DS3Typography.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitleText)
                        .font(DS3Typography.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.vertical, DS3Spacing.sm)

            // Neon progress bar for syncing/error rows
            if entry.status == .syncing || entry.status == .error {
                NeonProgressBar(color: statusColor, animate: entry.status == .syncing)
                    .padding(.horizontal, DS3Spacing.lg)
            }
        }
        .background(isHover ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHover = $0 }
        .onTapGesture {
            let vm = driveViewModel
            Task { try? await vm.openFinder() }
        }
        .contextMenu {
            Button {
                let vm = driveViewModel
                Task { try? await vm.openFinder() }
            } label: {
                Label(NSLocalizedString("Show in Finder", comment: "Recent file context menu"), systemImage: "folder")
            }

            if entry.status == .error {
                Button {
                    let vm = driveViewModel
                    Task { try? await vm.reEnumerate() }
                } label: {
                    Label(NSLocalizedString("Retry", comment: "Recent file context menu"), systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button {
                driveViewModel.recentFilesTracker.remove(id: entry.id)
            } label: {
                Label(NSLocalizedString("Dismiss", comment: "Recent file context menu"), systemImage: "xmark")
            }
        }
    }

    private var subtitleText: String {
        if entry.status == .syncing {
            var parts: [String] = []
            if let speed = entry.displaySpeed {
                parts.append(speed)
            }
            if let percent = entry.progressPercent {
                parts.append("\(percent)%")
            }
            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
        }
        return "\(entry.displaySize), \(relativeTime)"
    }

    private var statusIcon: String {
        switch entry.status {
        case .completed: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .completed: return DS3Colors.statusSynced
        case .syncing: return DS3Colors.statusSyncing
        case .error: return DS3Colors.statusError
        }
    }

    private var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(entry.timestamp))
        if seconds < 60 {
            return NSLocalizedString("Just now", comment: "Relative time")
        } else if seconds < 3600 {
            return String(format: NSLocalizedString("about %d min", comment: "Minutes ago"), seconds / 60)
        } else {
            return String(format: NSLocalizedString("%d hr ago", comment: "Hours ago"), seconds / 3600)
        }
    }
}

// MARK: - Neon Progress Bar

/// A thin glowing progress bar with animated neon shimmer — used for syncing file rows.
private struct NeonProgressBar: View {
    let color: Color
    let animate: Bool

    @State private var shimmerPhase: CGFloat = 0
    @State private var glowIntensity: CGFloat = 0.5

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Base bar
                Capsule()
                    .fill(color.opacity(animate ? 0.4 : 0.6))

                if animate {
                    // Shimmer highlight sliding across
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: color.opacity(0.3), location: max(0, shimmerPhase - 0.15)),
                                    .init(color: .white.opacity(0.9), location: shimmerPhase),
                                    .init(color: color.opacity(0.3), location: min(1, shimmerPhase + 0.15)),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .clipShape(Capsule())
            // Glow layers — pulse when animating
            .shadow(color: color.opacity(animate ? glowIntensity : 0.5), radius: animate ? 6 : 3, y: 0)
            .shadow(color: color.opacity(animate ? glowIntensity * 0.5 : 0.2), radius: animate ? 12 : 6, y: 0)
        }
        .frame(height: 2)
        .onAppear {
            guard animate else { return }
            // Shimmer sweep
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
            // Glow pulse
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowIntensity = 0.9
            }
        }
    }
}
