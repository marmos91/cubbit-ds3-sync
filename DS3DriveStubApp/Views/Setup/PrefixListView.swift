#if os(iOS)
import SwiftUI
import DS3Lib

/// Prefix folder drill-down view for browsing S3 folder structure within a bucket.
/// Users can navigate deeper into folders or select the current location as the drive root.
struct PrefixListView: View {
    let selection: BucketSelection
    var setupViewModel: SyncSetupViewModel
    @Binding var navigationPath: NavigationPath

    @Environment(DS3Authentication.self) private var ds3Authentication
    @State private var anchorVM: SyncAnchorSelectionViewModel?
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
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadFolders()
        }
    }

    private var displayTitle: String {
        if let prefix = selection.prefix {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.components(separatedBy: "/").last ?? selection.bucket.name
        }
        return selection.bucket.name
    }

    // MARK: - Shimmer Loading

    private var shimmerPlaceholder: some View {
        List {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: IOSSpacing.sm) {
                    Image(systemName: "folder")
                        .foregroundStyle(IOSColors.secondaryText)
                    Text("Loading folder name")
                        .font(IOSTypography.body)
                }
                .iosShimmering()
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Error State

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: IOSSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(Color.red)
            Text("Could not load folders. Check your connection and try again.")
                .font(IOSTypography.body)
                .foregroundStyle(Color.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.lg)
            Button("Retry") {
                Task { await loadFolders() }
            }
            .buttonStyle(IOSPrimaryButtonStyle())
            .padding(.horizontal, IOSSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: IOSSpacing.md) {
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(IOSColors.secondaryText)
            Text("This bucket is empty. You can select it as your drive root.")
                .font(IOSTypography.body)
                .foregroundStyle(IOSColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.lg)

            Button {
                selectCurrentLocation()
            } label: {
                Text("Select This Location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IOSPrimaryButtonStyle())
            .padding(.horizontal, IOSSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Folder List

    private var folderList: some View {
        List {
            ForEach(subfolders, id: \.self) { subfolder in
                Button {
                    navigationPath.append(
                        BucketSelection(
                            project: selection.project,
                            bucket: selection.bucket,
                            prefix: subfolder
                        )
                    )
                } label: {
                    HStack(spacing: IOSSpacing.sm) {
                        Image(systemName: "folder")
                            .foregroundStyle(IOSColors.accent)
                        Text(folderDisplayName(subfolder))
                            .font(IOSTypography.body)
                            .foregroundStyle(IOSColors.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(IOSTypography.caption)
                            .foregroundStyle(IOSColors.secondaryText)
                    }
                }
            }

            Section {
                Button {
                    selectCurrentLocation()
                } label: {
                    Text("Select This Location")
                        .font(IOSTypography.headline)
                        .foregroundStyle(IOSColors.accent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Helpers

    /// Extracts just the folder name from a full prefix path for display.
    private func folderDisplayName(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.components(separatedBy: "/").last ?? prefix
    }

    // MARK: - Data Loading

    private func loadFolders() async {
        loading = true
        error = nil

        let vm = SyncAnchorSelectionViewModel(
            project: selection.project,
            authentication: ds3Authentication
        )
        anchorVM = vm

        vm.selectBucket(selection.bucket)

        if let prefix = selection.prefix {
            vm.selectedPrefix = prefix
        }

        await vm.listFoldersForCurrentBucket()

        if let vmError = vm.error {
            self.error = vmError
        } else {
            let currentPrefix = selection.prefix ?? ""
            subfolders = vm.folders[currentPrefix] ?? []
        }

        loading = false
    }

    // MARK: - Actions

    private func selectCurrentLocation() {
        guard let vm = anchorVM else { return }

        vm.selectBucket(selection.bucket)
        vm.selectedPrefix = selection.prefix

        guard let anchor = vm.getSelectedSyncAnchor() else { return }
        setupViewModel.selectSyncAnchor(anchor: anchor)
        navigationPath.append(WizardConfirmStep())
    }
}
#endif
