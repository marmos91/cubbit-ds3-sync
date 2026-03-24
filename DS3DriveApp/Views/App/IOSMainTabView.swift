#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Adaptive layout that renders a TabView on iPhone (compact) and NavigationSplitView on iPad (regular).
    /// Automatically adapts to Split View, Slide Over, and Stage Manager via `horizontalSizeClass`.
    struct IOSMainTabView: View {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(DS3DriveManager.self) private var ds3DriveManager

        @State private var selectedTab: AppTab = .drives
        @State private var selectedDrive: DS3Drive?
        @State private var driveViewModel = IOSDriveViewModel(ipcService: makeDefaultIPCService())
        @State private var showWizard = false

        enum AppTab: Hashable {
            case drives
            case settings
        }

        var body: some View {
            Group {
                if horizontalSizeClass == .compact {
                    compactLayout
                } else {
                    regularLayout
                }
            }
            .fullScreenCover(isPresented: $showWizard) {
                IOSSetupWizardView()
                    .environment(ds3Authentication)
                    .environment(ds3DriveManager)
            }
            .onAppear {
                driveViewModel.loadPersistedPauseState(drives: ds3DriveManager.drives)
                driveViewModel.startListening()
            }
            .onDisappear {
                driveViewModel.stopListening()
            }
        }

        // MARK: - Compact Layout (iPhone / iPad Split View compact)

        private var compactLayout: some View {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    DriveListView(
                        selectedDrive: $selectedDrive,
                        showWizard: $showWizard,
                        driveViewModel: driveViewModel
                    )
                }
                .tabItem {
                    Label {
                        Text("Drives")
                    } icon: {
                        Image(.rawDriveIcon)
                            .renderingMode(.template)
                    }
                }
                .tag(AppTab.drives)

                NavigationStack {
                    IOSSettingsView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
            }
        }

        // MARK: - Regular Layout (iPad full screen / wide Split View)

        private var regularLayout: some View {
            NavigationSplitView {
                sidebarContent
                    .navigationTitle("DS3 Drive")
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
            } detail: {
                detailView
            }
        }

        // MARK: - Sidebar (iPad)

        private var sidebarContent: some View {
            List(selection: $selectedDrive) {
                Section("Drives") {
                    ForEach(ds3DriveManager.drives) { drive in
                        NavigationLink(value: drive) {
                            HStack(spacing: IOSSpacing.sm) {
                                ZStack(alignment: .bottomLeading) {
                                    Image(.rawDriveIcon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 24, height: 24)

                                    statusBadgeImage(for: driveViewModel.status(for: drive.id))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 10, height: 10)
                                        .offset(x: -2, y: 2)
                                }
                                Text(drive.name)
                                    .font(IOSTypography.body)
                                    .lineLimit(1)
                            }
                        }
                    }

                    if ds3DriveManager.drives.count < DefaultSettings.maxDrives {
                        Button {
                            showWizard = true
                        } label: {
                            Label("Add Drive", systemImage: "plus")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    } else {
                        Label("Add Drive", systemImage: "plus")
                            .foregroundStyle(IOSColors.secondaryText)
                    }
                }

                Section {
                    Button {
                        selectedTab = .settings
                        selectedDrive = nil
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
        }

        // MARK: - Helpers

        private func statusBadgeImage(for status: DS3DriveStatus) -> Image {
            switch status {
            case .idle: Image(.statusIdleBadge)
            case .sync, .indexing: Image(.statusSyncBadge)
            case .error: Image(.statusErrorBadge)
            case .paused: Image(.statusPauseBadge)
            }
        }

        // MARK: - Detail View (iPad right pane)

        @ViewBuilder private var detailView: some View {
            if selectedTab == .settings {
                IOSSettingsView()
            } else if let drive = selectedDrive {
                DriveDetailView(drive: drive, driveViewModel: driveViewModel)
            } else {
                Text("Select a drive")
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
            }
        }
    }
#endif
