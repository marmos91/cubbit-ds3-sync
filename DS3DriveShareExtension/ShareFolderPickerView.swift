#if os(iOS)
import SwiftUI
import DS3Lib

// MARK: - Folder Level

/// Represents a single level in the folder drill-down navigation.
struct FolderLevel: Hashable {
    let prefix: String
    let displayName: String
}

// MARK: - Folder Picker View

/// Folder drill-down view using NavigationStack for the Share Extension.
/// Mirrors the PrefixListView pattern from the main app, allowing users
/// to browse S3 folders and select an upload destination.
struct ShareFolderPickerView: View {
    @Bindable var viewModel: ShareUploadViewModel
    let onCancel: () -> Void

    @State private var folderPath: [FolderLevel] = []

    var body: some View {
        NavigationStack(path: $folderPath) {
            FolderLevelView(
                viewModel: viewModel,
                prefix: viewModel.selectedDrive?.syncAnchor.prefix ?? "",
                title: viewModel.selectedDrive?.name ?? "Choose Location",
                onCancel: onCancel,
                onUploadHere: { prefix in uploadHere(prefix: prefix) },
                onNavigate: { level in folderPath.append(level) }
            )
            .navigationDestination(for: FolderLevel.self) { level in
                FolderLevelView(
                    viewModel: viewModel,
                    prefix: level.prefix,
                    title: level.displayName,
                    onCancel: onCancel,
                    onUploadHere: { prefix in uploadHere(prefix: prefix) },
                    onNavigate: { level in folderPath.append(level) }
                )
            }
        }
    }

    // MARK: - Actions

    private func uploadHere(prefix: String?) {
        viewModel.selectFolder(prefix: prefix)
        Task { await viewModel.startUpload() }
    }
}

// MARK: - Folder Level View

/// Individual folder level content view. Used for both the root level
/// and drill-down levels in the NavigationStack.
private struct FolderLevelView: View {
    @Bindable var viewModel: ShareUploadViewModel
    let prefix: String
    let title: String
    let onCancel: () -> Void
    let onUploadHere: (String?) -> Void
    let onNavigate: (FolderLevel) -> Void

    @State private var subfolders: [String] = []
    @State private var loading = true
    @State private var error: Error?

    var body: some View {
        Group {
            if loading {
                shimmerPlaceholder
            } else if let error {
                errorView(error)
            } else if subfolders.isEmpty {
                emptyView
            } else {
                folderList
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                }
            }
        }
        .task {
            await loadFolders()
        }
    }

    // MARK: - Shimmer Loading

    private var shimmerPlaceholder: some View {
        List {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: ShareSpacing.sm) {
                    Image(systemName: "folder")
                        .foregroundStyle(ShareColors.secondaryText)
                    Text("Loading folder name")
                        .font(ShareTypography.body)
                }
                .redacted(reason: .placeholder)
                .opacity(0.6)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityLabel("Loading folders")
    }

    // MARK: - Error State

    @ViewBuilder
    private func errorView(_ error: Error) -> some View {
        VStack(spacing: ShareSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(ShareColors.statusError)

            Text("Could not load folders. Check your connection and try again.")
                .font(ShareTypography.body)
                .foregroundStyle(ShareColors.statusError)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ShareSpacing.lg)

            Button("Retry") {
                Task { await loadFolders() }
            }
            .buttonStyle(SharePrimaryButtonStyle())
            .padding(.horizontal, ShareSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: ShareSpacing.md) {
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(ShareColors.secondaryText)

            Text("No subfolders. Upload files to this location.")
                .font(ShareTypography.body)
                .foregroundStyle(ShareColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ShareSpacing.lg)

            Button("Upload Here") {
                onUploadHere(prefix.isEmpty ? nil : prefix)
            }
            .buttonStyle(SharePrimaryButtonStyle())
            .padding(.horizontal, ShareSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Folder List

    private var folderList: some View {
        List {
            ForEach(subfolders, id: \.self) { subfolder in
                Button {
                    onNavigate(FolderLevel(
                        prefix: subfolder,
                        displayName: folderDisplayName(subfolder)
                    ))
                } label: {
                    HStack(spacing: ShareSpacing.sm) {
                        Image(systemName: "folder")
                            .foregroundStyle(ShareColors.accent)
                        Text(folderDisplayName(subfolder))
                            .font(ShareTypography.body)
                            .foregroundStyle(ShareColors.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(ShareTypography.caption)
                            .foregroundStyle(ShareColors.secondaryText)
                    }
                }
            }

            Section {
                Button {
                    onUploadHere(prefix.isEmpty ? nil : prefix)
                } label: {
                    HStack {
                        Spacer()
                        Label("Upload Here", systemImage: "arrow.up.circle.fill")
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
        .listStyle(.insetGrouped)
    }

    // MARK: - Helpers

    private func folderDisplayName(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.components(separatedBy: "/").last ?? prefix
    }

    // MARK: - Data Loading

    private func loadFolders() async {
        loading = true
        error = nil
        defer { loading = false }

        guard let drive = viewModel.selectedDrive else { return }

        let vm = SyncAnchorSelectionViewModel(
            project: drive.syncAnchor.project,
            authentication: DS3Authentication.loadFromPersistenceOrCreateNew()
        )

        vm.selectBucket(Bucket(name: drive.syncAnchor.bucket.name))

        let currentPrefix = prefix.isEmpty ? nil : prefix
        vm.selectedPrefix = currentPrefix

        await vm.listFoldersForCurrentBucket()

        if let vmError = vm.error {
            self.error = vmError
        } else {
            subfolders = vm.folders[currentPrefix ?? ""] ?? []
        }
    }
}
#endif
