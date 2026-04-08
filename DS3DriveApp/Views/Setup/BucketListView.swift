#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Searchable bucket list — second step of the drive setup wizard.
    /// Matches the `ProjectListView` design language: brand gradient
    /// backdrop, Figtree typography, custom `BucketIcon` asset (aligned
    /// with the macOS tree view), branded empty / error states, and
    /// haptic feedback on row taps.
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
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

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
            }
            .searchable(text: $searchText, prompt: "Search buckets")
            .refreshable {
                await anchorVM?.loadBuckets()
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    iamUserMenu
                }
            }
            .task {
                // Reuse the shared anchor VM hoisted on SyncSetupViewModel
                // so that PrefixListView can reuse the same s3Client and
                // IAM credentials — avoids the SlowDown throttling we hit
                // when each wizard step forged its own token.
                let vm = setupViewModel.ensureAnchorViewModel(
                    for: project,
                    authentication: ds3Authentication
                )
                anchorVM = vm
                if vm.buckets.isEmpty {
                    await vm.loadBuckets()
                }
            }
        }

        // MARK: - Bucket List

        private var bucketList: some View {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredBuckets) { bucket in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            navigationPath.append(
                                BucketSelection(
                                    project: project,
                                    bucket: bucket,
                                    prefix: nil
                                )
                            )
                        } label: {
                            bucketRow(bucket)
                        }
                        .buttonStyle(SetupRowPressStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }

        private func bucketRow(_ bucket: Bucket) -> some View {
            HStack(spacing: 14) {
                Image(.bucketIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.name)
                        .font(.custom("Figtree-SemiBold", size: 16))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("Tap to browse folders")
                        .font(.custom("Figtree-Regular", size: 13))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
            )
        }

        // MARK: - IAM User Menu

        private var iamUserMenu: some View {
            Menu {
                ForEach(project.users, id: \.id) { user in
                    Button {
                        let vm = anchorVM
                        Task { await vm?.selectIAMUser(withID: user.id) }
                    } label: {
                        HStack {
                            Text(user.username)
                            if user.isRoot { Text("(root)") }
                            if user.id == anchorVM?.selectedIAMUser?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(anchorVM?.selectedIAMUser?.username ?? "User")
                        .font(.custom("Figtree-SemiBold", size: 14))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(IOSColors.brandPrimary)
            }
        }

        // MARK: - Shimmer Loading

        private var shimmerPlaceholder: some View {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0 ..< 5, id: \.self) { _ in
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(IOSColors.brandBorderSubtle)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(IOSColors.brandBorderSubtle)
                                    .frame(width: 160, height: 14)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(IOSColors.brandBorderSubtle)
                                    .frame(width: 100, height: 11)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
                        )
                        .iosShimmering()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }

        // MARK: - Error State

        private var isAuthError: Bool {
            anchorVM?.authenticationError != nil
        }

        private func errorView(_: Error) -> some View {
            VStack(spacing: 20) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(IOSColors.statusError.opacity(0.12))
                        .frame(width: 96, height: 96)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(IOSColors.statusError)
                }

                VStack(spacing: 8) {
                    Text(isAuthError ? "Session Expired" : "Couldn't Load Buckets")
                        .font(.custom("Figtree-SemiBold", size: 20))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                    Text(isAuthError
                        ? "Your session has expired. Please log in again."
                        : "Check your connection and try again.")
                        .font(.custom("Figtree-Regular", size: 15))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if isAuthError {
                        ds3Authentication.logout()
                    } else {
                        Task { await anchorVM?.loadBuckets() }
                    }
                } label: {
                    Text(isAuthError ? "Log Out" : "Retry")
                        .font(.custom("Figtree-SemiBold", size: 17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(IOSColors.brandPrimary)
                        )
                }
                .buttonStyle(SetupRowPressStyle())
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Empty State

        private var emptyView: some View {
            VStack(spacing: 20) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(IOSColors.brandPrimary.opacity(0.12))
                        .frame(width: 96, height: 96)

                    Image(.bucketIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }

                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "No Buckets Yet" : "No Matches")
                        .font(.custom("Figtree-SemiBold", size: 20))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                    Text(searchText.isEmpty
                        ? "Create a bucket in the DS3 Console to get started."
                        : "Try a different search term.")
                        .font(.custom("Figtree-Regular", size: 15))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Row Press Style

    /// Subtle scale+opacity press feedback shared across tappable rows
    /// in the setup wizard.
    private struct SetupRowPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
