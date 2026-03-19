#if os(iOS)
import SwiftUI
import DS3Lib

// MARK: - Upload Progress View

/// Per-file upload progress list with cancel confirmation and auto-dismiss.
/// Shows overall progress, individual file statuses, and retry options for failures.
struct ShareUploadProgressView: View {
    @Bindable var viewModel: ShareUploadViewModel
    let onCancel: () -> Void

    @State private var showCancelAlert = false

    var body: some View {
        List {
            // Overall progress section
            Section {
                VStack(alignment: .leading, spacing: ShareSpacing.sm) {
                    Text("\(viewModel.completedCount) of \(viewModel.files.count) files uploaded")
                        .font(ShareTypography.caption)
                        .foregroundStyle(ShareColors.secondaryText)

                    ProgressView(value: viewModel.overallProgress)
                        .tint(ShareColors.accent)
                }
            }

            // Per-file progress section
            Section {
                ForEach(viewModel.files) { file in
                    fileRow(file)
                }
            }

            // Retry section for partial failure
            if viewModel.state == .partialFailure {
                Section {
                    Button {
                        Task { await viewModel.retryFailed() }
                    } label: {
                        HStack {
                            Spacer()
                            Label("Retry Failed", systemImage: "arrow.clockwise")
                                .font(ShareTypography.headline)
                            Spacer()
                        }
                    }
                    .buttonStyle(SharePrimaryButtonStyle())
                    .listRowInsets(EdgeInsets(
                        top: ShareSpacing.sm,
                        leading: ShareSpacing.md,
                        bottom: ShareSpacing.sm,
                        trailing: ShareSpacing.md
                    ))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.state == .uploading {
                    Button("Cancel") {
                        showCancelAlert = true
                    }
                }
            }
        }
        .alert("Cancel Upload?", isPresented: $showCancelAlert) {
            Button("Continue Uploading", role: .cancel) { }
            Button("Cancel Upload", role: .destructive) { onCancel() }
        } message: {
            Text("Files that have already been uploaded will remain in your drive.")
        }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .complete {
                UIAccessibility.post(notification: .announcement, argument: "Upload complete")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(
                        name: Notification.Name("ShareExtensionComplete"),
                        object: nil
                    )
                }
            }
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        switch viewModel.state {
        case .complete:
            return "Upload Complete"
        case .partialFailure:
            return "Upload Failed"
        default:
            return "Uploading..."
        }
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(_ file: SharedFileItem) -> some View {
        HStack(spacing: ShareSpacing.sm) {
            Image(systemName: fileTypeIcon(for: file))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ShareColors.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: ShareSpacing.xs) {
                Text(file.filename)
                    .font(ShareTypography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if case .failed(let message) = file.status {
                    Text(message)
                        .font(ShareTypography.caption)
                        .foregroundStyle(ShareColors.statusError)
                        .lineLimit(2)
                }
            }

            Spacer()

            statusIcon(for: file)
        }
        .accessibilityLabel("\(file.filename), \(statusDescription(for: file))")
        .accessibilityValue(progressValue(for: file))
    }

    // MARK: - Status Icon

    @ViewBuilder
    private func statusIcon(for file: SharedFileItem) -> some View {
        switch file.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(ShareColors.secondaryText)
        case .uploading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .frame(width: 24, height: 24)
                .tint(ShareColors.accent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ShareColors.statusSynced)
        case .failed:
            Button {
                Task { await viewModel.retryFailed() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(ShareColors.statusError)
            }
        }
    }

    // MARK: - Helpers

    private func fileTypeIcon(for file: SharedFileItem) -> String {
        viewModel.iconForFile(file)
    }

    private func statusDescription(for file: SharedFileItem) -> String {
        switch file.status {
        case .pending:
            return "Pending"
        case .uploading:
            return "Uploading"
        case .completed:
            return "Uploaded"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private func progressValue(for file: SharedFileItem) -> String {
        switch file.status {
        case .uploading(let progress):
            return "\(Int(progress * 100)) percent"
        default:
            return ""
        }
    }
}
#endif
