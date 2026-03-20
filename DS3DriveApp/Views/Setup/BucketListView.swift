#if os(iOS)
import SwiftUI
import DS3Lib

/// Searchable bucket list with drill-down to prefix selection.
/// Second step of the drive setup wizard. Tap a bucket to browse its prefixes,
/// or tap "Select This Location" to use the bucket root.
struct BucketListView: View {
    let project: Project
    var setupViewModel: SyncSetupViewModel
    @Binding var navigationPath: NavigationPath

    @Environment(DS3Authentication.self) private var ds3Authentication
    @State private var anchorVM: SyncAnchorSelectionViewModel?
    @State private var searchText = ""

    private var filteredBuckets: [Bucket] {
        guard let buckets = anchorVM?.buckets else { return [] }
        if searchText.isEmpty { return buckets }
        return buckets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if anchorVM?.loading == true {
                shimmerPlaceholder
            } else if let error = anchorVM?.error ?? anchorVM?.authenticationError {
                errorView(error)
            } else if filteredBuckets.isEmpty {
                emptyView
            } else {
                bucketList
            }
        }
        .searchable(text: $searchText, prompt: "Search buckets")
        .refreshable {
            await anchorVM?.loadBuckets()
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if anchorVM == nil {
                let vm = SyncAnchorSelectionViewModel(
                    project: project,
                    authentication: ds3Authentication
                )
                anchorVM = vm
                await vm.loadBuckets()
            }
        }
    }

    // MARK: - Shimmer Loading

    private var shimmerPlaceholder: some View {
        List {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: IOSSpacing.sm) {
                    Image(systemName: "cylinder")
                        .foregroundStyle(IOSColors.secondaryText)
                    Text("Loading bucket name")
                        .font(IOSTypography.body)
                }
                .iosShimmering()
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Error State

    private var isAuthError: Bool {
        anchorVM?.authenticationError != nil
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: IOSSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(Color.red)
            Text(isAuthError
                ? "Your session has expired. Please log in again."
                : "Could not load buckets. Check your connection and try again.")
                .font(IOSTypography.body)
                .foregroundStyle(Color.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.lg)

            if isAuthError {
                Button("Logout") {
                    ds3Authentication.logout()
                }
                .buttonStyle(IOSPrimaryButtonStyle())
                .padding(.horizontal, IOSSpacing.xl)
            } else {
                Button("Retry") {
                    Task { await anchorVM?.loadBuckets() }
                }
                .buttonStyle(IOSPrimaryButtonStyle())
                .padding(.horizontal, IOSSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: IOSSpacing.md) {
            Image(systemName: "cylinder")
                .font(.largeTitle)
                .foregroundStyle(IOSColors.secondaryText)
            Text("No buckets found. Create a bucket in the DS3 Console.")
                .font(IOSTypography.body)
                .foregroundStyle(IOSColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bucket List

    private var bucketList: some View {
        List {
            ForEach(filteredBuckets) { bucket in
                Button {
                    navigationPath.append(
                        BucketSelection(
                            project: project,
                            bucket: bucket,
                            prefix: nil
                        )
                    )
                } label: {
                    HStack(spacing: IOSSpacing.sm) {
                        Image(systemName: "cylinder")
                            .foregroundStyle(IOSColors.accent)
                        Text(bucket.name)
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
                    selectBucketRoot()
                } label: {
                    Text("Select This Location")
                        .font(IOSTypography.headline)
                        .foregroundStyle(IOSColors.accent)
                        .frame(maxWidth: .infinity)
                }
                .disabled(filteredBuckets.isEmpty)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func selectBucketRoot() {
        guard let bucket = anchorVM?.selectedBucket ?? filteredBuckets.first else { return }

        anchorVM?.selectBucket(bucket)

        guard let anchor = anchorVM?.getSelectedSyncAnchor() else { return }
        setupViewModel.selectSyncAnchor(anchor: anchor)
        navigationPath.append(WizardConfirmStep())
    }
}
#endif
