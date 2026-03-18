#if os(iOS)
import SwiftUI
import DS3Lib

/// Settings screen with Account, General, and About sections.
/// Provides account info display, tap-to-copy connection info, sync notification toggle,
/// cache management, and logout with File Provider domain cleanup.
struct IOSSettingsView: View {
    @Environment(DS3Authentication.self) private var ds3Authentication
    @Environment(DS3DriveManager.self) private var ds3DriveManager

    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false
    @State private var cacheSize: Int64 = 0
    @State private var isClearingCache = false
    @State private var isLoggingOut = false
    @State private var syncNotificationsEnabled: Bool = UserDefaults.standard.bool(forKey: "syncNotificationsEnabled")
    @State private var copiedFieldId: String?

    private var account: Account? { ds3Authentication.account }

    private var tenantName: String {
        (try? SharedData.default().loadTenantNameFromPersistence()) ?? DefaultSettings.defaultTenantName
    }

    private var coordinatorURL: String {
        (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
    }

    var body: some View {
        List {
            accountSection
            generalSection
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
                // Name row
                HStack {
                    Text("Name")
                        .font(IOSTypography.body)
                    Spacer()
                    Text("\(account.firstName) \(account.lastName)")
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }

                // Email row
                HStack {
                    Text("Email")
                        .font(IOSTypography.body)
                    Spacer()
                    Text(account.emails.first?.email ?? "")
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }

                // Tenant row
                HStack {
                    Text("Tenant")
                        .font(IOSTypography.body)
                    Spacer()
                    Text(tenantName)
                        .font(IOSTypography.body)
                        .foregroundStyle(IOSColors.secondaryText)
                }

                // Connection info row (tap-to-copy)
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

                // Manage Account link
                Link(destination: URL(string: "https://console.cubbit.io")!) {
                    HStack {
                        Text("Manage Account")
                            .font(IOSTypography.body)
                        Spacer()
                        Image(systemName: "safari")
                            .foregroundStyle(IOSColors.accent)
                    }
                }

                // Sign Out button
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
            // Sync Notifications toggle
            Toggle(isOn: Binding(
                get: { syncNotificationsEnabled },
                set: { newValue in
                    syncNotificationsEnabled = newValue
                    UserDefaults.standard.set(newValue, forKey: "syncNotificationsEnabled")
                }
            )) {
                Text("Sync Notifications")
                    .font(IOSTypography.body)
            }

            // Cache row
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

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            // Version row
            HStack {
                Text("Version")
                    .font(IOSTypography.body)
                Spacer()
                Text("v\(DefaultSettings.appVersion) (\(DefaultSettings.appBuild))")
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSColors.secondaryText)
            }

            // Licenses row
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

            // Support link
            Link(destination: URL(string: "https://support.cubbit.io")!) {
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
