#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Prefix/folder drill-down view — third step of the drive setup
    /// wizard. Matches the brand design language used by `BucketListView`
    /// and `ProjectListView`: gradient backdrop, Figtree typography,
    /// branded rows with folder glyphs, and a pinned "Select This
    /// Location" CTA at the bottom.
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
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                Group {
                    if loading {
                        shimmerPlaceholder
                    } else if let error {
                        errorView(error)
                    } else if subfolders.isEmpty {
                        emptyView
                    } else {
                        folderContent
                    }
                }
            }
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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

        // MARK: - Folder Content (list + pinned CTA)

        private var folderContent: some View {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(subfolders, id: \.self) { subfolder in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                navigationPath.append(
                                    BucketSelection(
                                        project: selection.project,
                                        bucket: selection.bucket,
                                        prefix: subfolder
                                    )
                                )
                            } label: {
                                folderRow(subfolder)
                            }
                            .buttonStyle(PrefixRowPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }

                selectLocationCTA
            }
        }

        private func folderRow(_ prefix: String) -> some View {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(IOSColors.brandPrimary)
                    .frame(width: 32, height: 32)

                Text(folderDisplayName(prefix))
                    .font(.custom("Figtree-SemiBold", size: 16))
                    .foregroundStyle(IOSColors.brandTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

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

        private var selectLocationCTA: some View {
            VStack(spacing: 0) {
                Divider()
                    .background(IOSColors.brandBorderSubtle)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    selectCurrentLocation()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Select This Location")
                            .font(.custom("Figtree-SemiBold", size: 17))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(IOSColors.brandPrimary)
                    )
                }
                .buttonStyle(PrefixRowPressStyle())
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .background(.ultraThinMaterial)
        }

        // MARK: - Helpers

        private func folderDisplayName(_ prefix: String) -> String {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.components(separatedBy: "/").last ?? prefix
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

                            RoundedRectangle(cornerRadius: 4)
                                .fill(IOSColors.brandBorderSubtle)
                                .frame(width: 160, height: 14)

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
                    Text("Couldn't Load Folders")
                        .font(.custom("Figtree-SemiBold", size: 20))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                    Text("Check your connection and try again.")
                        .font(.custom("Figtree-Regular", size: 15))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await loadFolders() }
                } label: {
                    Text("Retry")
                        .font(.custom("Figtree-SemiBold", size: 17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(IOSColors.brandPrimary)
                        )
                }
                .buttonStyle(PrefixRowPressStyle())
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Empty State

        private var emptyView: some View {
            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(IOSColors.brandPrimary.opacity(0.12))
                        .frame(width: 96, height: 96)

                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(IOSColors.brandPrimary)
                }

                VStack(spacing: 8) {
                    Text("No Subfolders")
                        .font(.custom("Figtree-SemiBold", size: 20))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                    Text("Select this location as your drive root.")
                        .font(.custom("Figtree-Regular", size: 15))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    selectCurrentLocation()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Select This Location")
                            .font(.custom("Figtree-SemiBold", size: 17))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(IOSColors.brandPrimary)
                    )
                }
                .buttonStyle(PrefixRowPressStyle())
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Data Loading

        private func loadFolders() async {
            // Back-navigation re-fires `.task`, which would re-run
            // listObjects and stomp on the shared anchor VM's folder
            // cache for siblings at other prefix depths. Return early if
            // we already loaded this view's subfolders successfully.
            if !subfolders.isEmpty { return }

            loading = true
            error = nil
            defer { loading = false }

            // Reuse the shared anchor VM from the wizard so we don't forge
            // a new IAM token on every push (root cause of S3 SlowDown).
            let vm = setupViewModel.ensureAnchorViewModel(
                for: selection.project,
                authentication: ds3Authentication
            )
            anchorVM = vm

            vm.selectBucket(selection.bucket)
            vm.selectedPrefix = selection.prefix

            await vm.listFoldersForCurrentBucket()

            if let vmError = vm.error {
                self.error = vmError
            } else {
                subfolders = vm.folders[selection.prefix ?? ""] ?? []
            }
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

    // MARK: - Row Press Style

    private struct PrefixRowPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
