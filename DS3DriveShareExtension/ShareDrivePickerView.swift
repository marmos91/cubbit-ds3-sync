#if os(iOS)
import SwiftUI
import DS3Lib

// MARK: - Drive Picker View

/// Drive selection list for the Share Extension.
/// Shows available drives with a checkmark on the last-used drive.
/// Tapping a drive selects it and advances to the folder picker.
struct ShareDrivePickerView: View {
    @Bindable var viewModel: ShareUploadViewModel
    let onCancel: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(viewModel.drives) { drive in
                    Button {
                        viewModel.selectDrive(drive)
                    } label: {
                        driveRow(drive)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Drive \(drive.name), bucket \(drive.syncAnchor.bucket.name)")
                }
            }

            Section {
                HStack {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(ShareColors.secondaryText)
                    Text("\(viewModel.files.count) file(s) selected")
                        .font(ShareTypography.body)
                    Spacer()
                    Text(viewModel.formattedSize(viewModel.totalFileSize))
                        .font(ShareTypography.caption)
                        .foregroundStyle(ShareColors.secondaryText)
                }
            } header: {
                Text("FILES")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Upload to DS3 Drive")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                }
            }
        }
    }

    // MARK: - Drive Row

    @ViewBuilder
    private func driveRow(_ drive: DS3Drive) -> some View {
        HStack(spacing: ShareSpacing.sm) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(ShareColors.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: ShareSpacing.xs) {
                Text(drive.name)
                    .font(ShareTypography.headline)
                    .foregroundStyle(ShareColors.primaryText)

                Text("s3://\(drive.syncAnchor.bucket.name)/\(drive.syncAnchor.prefix ?? "")")
                    .font(ShareTypography.caption)
                    .foregroundStyle(ShareColors.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if drive.id == viewModel.lastUsedDriveId {
                Image(systemName: "checkmark")
                    .foregroundStyle(ShareColors.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
