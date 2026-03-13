import SwiftUI
import DS3Lib

/// Side panel showing recent files per drive, matching the Figma file status design.
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
                        .font(DS3Typography.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
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
                    VStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "doc")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text(NSLocalizedString("No recent files", comment: "Empty recent files"))
                            .font(DS3Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let sorted = recentFiles.sorted { $0.status < $1.status }
                        ForEach(sorted.prefix(10)) { entry in
                            RecentFileRow(entry: entry, driveViewModel: driveViewModel)
                        }
                    }
                }
            }
        }
    }
}

/// A single row in the recent files panel — Figma style with status icon, name, size + time.
private struct RecentFileRow: View {
    let entry: RecentFileEntry
    let driveViewModel: DS3DriveViewModel
    @State private var isHover = false

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .frame(width: 18, alignment: .center)

            // File info
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.filename)
                    .font(DS3Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(entry.displaySize), \(relativeTime)")
                    .font(DS3Typography.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.xs)
        .background(isHover ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHover = $0 }
        .onTapGesture {
            let vm = driveViewModel
            Task { try? await vm.openFinder() }
        }
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
