import SwiftUI
import DS3Lib

/// Side panel showing recent files per drive, displayed when activeSidePanel = .recentFiles(driveId).
struct RecentFilesPanel: View {
    let driveName: String
    let recentFiles: [RecentFileEntry]
    let driveViewModel: DS3DriveViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(driveName)
                        .font(DS3Typography.headline)
                        .lineLimit(1)
                    Text(NSLocalizedString("Recent Files", comment: "Recent files panel title"))
                        .font(DS3Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.vertical, DS3Spacing.md)

            Divider()

            // File list
            if recentFiles.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text(NSLocalizedString("No recent files", comment: "Empty recent files"))
                        .font(DS3Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let sorted = recentFiles.sorted { $0.status < $1.status }
                        ForEach(sorted.prefix(10)) { entry in
                            RecentFileRow(entry: entry, driveViewModel: driveViewModel)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// A single row in the recent files panel.
private struct RecentFileRow: View {
    let entry: RecentFileEntry
    let driveViewModel: DS3DriveViewModel

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.filename)
                    .font(DS3Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: DS3Spacing.xs) {
                    Text(entry.displaySize)
                        .font(DS3Typography.footnote)
                        .foregroundStyle(.secondary)

                    Text(relativeTime)
                        .font(DS3Typography.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            revealInFinder()
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .completed:
            return DS3Colors.statusSynced
        case .syncing:
            return DS3Colors.statusSyncing
        case .error:
            return DS3Colors.statusError
        }
    }

    private var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(entry.timestamp))
        if seconds < 60 {
            return NSLocalizedString("Just now", comment: "Relative time")
        } else if seconds < 3600 {
            return String(format: NSLocalizedString("%d min ago", comment: "Minutes ago"), seconds / 60)
        } else {
            return String(format: NSLocalizedString("%d hr ago", comment: "Hours ago"), seconds / 3600)
        }
    }

    private func revealInFinder() {
        // Open drive root in Finder as a fallback (individual file paths require NSFileProviderManager lookup)
        let vm = driveViewModel
        Task {
            try? await vm.openFinder()
        }
    }
}
