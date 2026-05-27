import DS3Lib
import SwiftUI

/// Side panel showing recent files per drive, matching the Figma file status design.
/// Reads `driveViewModel.recentFiles` directly so @Observable triggers live updates.
struct RecentFilesPanel: View {
    let driveViewModel: DS3DriveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if driveViewModel.recentFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .padding(.vertical, DS3Spacing.sm)
        // Plan 05-12: brand surface so the panel matches the tray cards.
        .background(DS3Colors.brandSurface)
    }

    // MARK: - Header

    /// Header row with the panel title and a Clear action (Gap 14).
    /// Clicking Clear empties the per-drive tracker so stale entries can be
    /// dismissed all at once.
    private var header: some View {
        HStack {
            Text(NSLocalizedString(
                "recentFiles.title",
                value: "Recent Files",
                comment: "Recent files panel title"
            ))
            .font(DS3Typography.caption.bold())
            .foregroundStyle(DS3Colors.brandTextSecondary)

            Spacer()

            Button {
                driveViewModel.recentFilesTracker.clearAll(forDrive: driveViewModel.drive.id)
                driveViewModel.refreshRecentFiles()
            } label: {
                Text(NSLocalizedString(
                    "recentFiles.clear",
                    value: "Clear",
                    comment: "Recent files panel clear button"
                ))
                .font(DS3Typography.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS3Colors.brandTextSecondary)
            .disabled(driveViewModel.recentFiles.isEmpty)
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.bottom, DS3Spacing.xs)
    }

    // MARK: - File List

    private var fileList: some View {
        ForEach(driveViewModel.recentFiles.prefix(10)) { entry in
            RecentFileRow(entry: entry, driveViewModel: driveViewModel)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DS3Spacing.sm) {
            Image(systemName: "doc")
                .font(.system(size: 20))
                .foregroundStyle(DS3Colors.brandTextSecondary)
            Text(NSLocalizedString("No recent files", comment: "Empty recent files"))
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.brandTextSecondary)
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
                        .foregroundStyle(DS3Colors.brandTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitleText)
                        .font(DS3Typography.footnote)
                        .foregroundStyle(DS3Colors.brandTextSecondary)
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
        .background(DS3Colors.brandPrimary.opacity(isHover ? 0.08 : 0))
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
                    Label(
                        NSLocalizedString("Retry", comment: "Recent file context menu"),
                        systemImage: "arrow.clockwise"
                    )
                }
            }

            Divider()

            Button {
                driveViewModel.recentFilesTracker.remove(id: entry.id)
                driveViewModel.refreshRecentFiles()
            } label: {
                Label(NSLocalizedString("Dismiss", comment: "Recent file context menu"), systemImage: "xmark")
            }
        }
    }

    private var subtitleText: String {
        if entry.status == .syncing {
            let parts = [
                entry.displaySpeed,
                entry.progressPercent.map { "\($0)%" }
            ].compactMap(\.self)

            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
        }
        return "\(entry.displaySize), \(relativeTime)"
    }

    private var statusIcon: String {
        switch entry.status {
        case .completed: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .completed: DS3Colors.statusSynced
        case .syncing: DS3Colors.statusSyncing
        case .error: DS3Colors.statusError
        }
    }

    private var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(entry.timestamp))
        if seconds < 60 {
            return NSLocalizedString("Just now", comment: "Relative time")
        }
        if seconds < 3600 {
            return String(format: NSLocalizedString("about %d min", comment: "Minutes ago"), seconds / 60)
        }
        return String(format: NSLocalizedString("%d hr ago", comment: "Hours ago"), seconds / 3600)
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
