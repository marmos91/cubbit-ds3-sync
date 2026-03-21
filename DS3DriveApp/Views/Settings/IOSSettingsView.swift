#if os(iOS)
import SwiftUI
import DS3Lib

/// Settings screen with Account, General, and About sections.
/// Provides account info display, tap-to-copy connection info, sync notification toggle,
/// cache management, and logout with File Provider domain cleanup.
struct IOSSettingsView: View {
    @Environment(DS3Authentication.self) private var ds3Authentication
    @Environment(DS3DriveManager.self) private var ds3DriveManager
    @Environment(UpdateChecker.self) private var updateChecker

    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false
    @State private var cacheSize: Int64 = 0
    @State private var isClearingCache = false
    @State private var isLoggingOut = false
    @AppStorage("syncNotificationsEnabled") private var syncNotificationsEnabled = false
    @State private var copiedFieldId: String?

    private var account: Account? { ds3Authentication.account }

    private var tenantName: String {
        let tenant = (try? SharedData.default().loadTenantNameFromPersistence()) ?? ""
        return tenant.isEmpty ? DefaultSettings.defaultTenantName : tenant
    }

    private var coordinatorURL: String {
        (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
    }

    var body: some View {
        List {
            accountSection
            generalSection
            updatesSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .alert("Sign Out", isPresented: $showLogoutAlert) {
            Button("Sign Out", role: .destructive) {
                Task { await performLogout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out will disconnect all drives. Your files in S3 are not affected.")
        }
        .alert("Clear Cache", isPresented: $showClearCacheAlert) {
            Button("Clear Cache", role: .destructive) {
                Task { await performClearCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all downloaded files. They will be re-downloaded when you open them.")
        }
        .task {
            cacheSize = await CacheManager.calculateCacheSize()
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            if let account {
                HStack {
                    Text("Name")
                        .font(IOSTypography.body)
                    Spacer()
                    Text("\(account.firstName) \(account.lastName)")
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }

                HStack {
                    Text("Email")
                        .font(IOSTypography.body)
                    Spacer()
                    Text(account.emails.first?.email ?? "")
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }

                HStack {
                    Text("Tenant")
                        .font(IOSTypography.body)
                    Spacer()
                    Text(tenantName)
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }

                Button {
                    copyToClipboard(coordinatorURL, fieldId: "connectionInfo")
                } label: {
                    HStack {
                        Text("Connection Info")
                            .font(IOSTypography.body)
                            .foregroundStyle(IOSColors.primaryText)
                        Spacer()
                        if copiedFieldId == "connectionInfo" {
                            Text("Copied")
                                .font(IOSTypography.caption)
                                .foregroundStyle(IOSColors.accent)
                                .transition(.opacity)
                        } else {
                            Text(coordinatorURL)
                                .font(IOSTypography.caption)
                                .foregroundStyle(IOSColors.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Link(destination: URL(string: ConsoleURLs.profileURL)!) {
                    HStack {
                        Text("Manage Account")
                            .font(IOSTypography.body)
                        Spacer()
                        Image(systemName: "safari")
                            .foregroundStyle(IOSColors.accent)
                    }
                }

                Button(role: .destructive) {
                    showLogoutAlert = true
                } label: {
                    HStack {
                        if isLoggingOut {
                            ProgressView()
                                .controlSize(.small)
                            Text("Signing Out...")
                                .font(IOSTypography.body)
                        } else {
                            Text("Sign Out")
                                .font(IOSTypography.body)
                        }
                    }
                }
                .disabled(isLoggingOut)
            }
        } header: {
            Label("Account", systemImage: "person.crop.circle")
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        Section {
            HStack {
                Text("Active Drives")
                    .font(IOSTypography.body)
                Spacer()
                Text("\(ds3DriveManager.drives.count)")
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
            }

            Toggle(isOn: $syncNotificationsEnabled) {
                Text("Sync Notifications")
                    .font(IOSTypography.body)
            }

            HStack {
                Text("Cache")
                    .font(IOSTypography.body)
                Spacer()
                if isClearingCache {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(CacheManager.formatSize(cacheSize))
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }
                Button("Clear Cache", role: .destructive) {
                    showClearCacheAlert = true
                }
                .font(IOSTypography.caption)
                .disabled(isClearingCache)
            }
        } header: {
            Label("General", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: - Updates Section

    private var updatesSection: some View {
        Section {
            Button {
                if updateChecker.updateAvailable {
                    openUpdateDestination()
                } else {
                    Task { await updateChecker.checkForUpdates() }
                }
            } label: {
                HStack {
                    if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                        Text("Update Available: \(version)")
                            .font(IOSTypography.body)
                            .foregroundStyle(IOSColors.accent)
                    } else {
                        Text("Check for Updates")
                            .font(IOSTypography.body)
                            .foregroundStyle(IOSColors.primaryText)
                    }
                    Spacer()
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(updateChecker.isChecking)

            HStack {
                Text("Distribution")
                    .font(IOSTypography.body)
                Spacer()
                Text(updateChecker.channel.displayName)
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
            }
        } header: {
            Label("Updates", systemImage: "arrow.down.circle")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(IOSTypography.body)
                Spacer()
                Text("v\(DefaultSettings.appVersion) (\(DefaultSettings.appBuild))")
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
            }

            NavigationLink {
                ScrollView {
                    Text("Open Source Licenses\n\nThis application uses the following open source libraries:\n\n- Soto for AWS (Apache 2.0)\n- Swift Atomics (Apache 2.0)\n- Swift NIO (Apache 2.0)")
                        .font(IOSTypography.body)
                        .padding()
                }
                .navigationTitle("Licenses")
            } label: {
                Text("Licenses")
                    .font(IOSTypography.body)
            }

            Link(destination: URL(string: HelpURLs.baseURL)!) {
                HStack {
                    Text("Support")
                        .font(IOSTypography.body)
                    Spacer()
                    Image(systemName: "safari")
                        .foregroundStyle(IOSColors.accent)
                }
            }
        } header: {
            Label("About", systemImage: "info.circle")
        }
    }

    // MARK: - Actions

    private func copyToClipboard(_ value: String, fieldId: String) {
        UIPasteboard.general.string = value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        withAnimation {
            copiedFieldId = fieldId
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                if copiedFieldId == fieldId {
                    copiedFieldId = nil
                }
            }
        }
    }

    private func openUpdateDestination() {
        switch updateChecker.channel {
        case .testFlight:
            UIApplication.shared.open(URL(string: "itms-beta://")!)
        case .appStore:
            UIApplication.shared.open(URL(string: "itms-apps://apps.apple.com")!)
        }
    }

    private func performLogout() async {
        isLoggingOut = true
        try? await ds3DriveManager.cleanFileProvider()
        ds3Authentication.logout()
        isLoggingOut = false
    }

    private func performClearCache() async {
        isClearingCache = true
        try? await CacheManager.clearCache()
        cacheSize = await CacheManager.calculateCacheSize()
        isClearingCache = false
    }
}
#endif
