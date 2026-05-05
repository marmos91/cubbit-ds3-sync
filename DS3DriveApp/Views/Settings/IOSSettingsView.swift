#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Settings screen — Account, General, Updates, About.
    /// Matches the rest of the iOS app: brand gradient backdrop, Figtree
    /// typography, bigger iOS-native sizes, branded card sections, and
    /// haptic feedback on destructive taps.
    struct IOSSettingsView: View {
        @Environment(DS3Authentication.self) private var ds3Authentication
        @Environment(DS3DriveManager.self) private var ds3DriveManager
        @Environment(UpdateChecker.self) private var updateChecker
        @Environment(ForegroundBackfillDriver.self) private var thumbnailBackfillDriver
        @Environment(\.openURL) private var openURL

        @State private var showLogoutAlert = false
        @State private var showClearCacheAlert = false
        @State private var showGenerateNowAlert = false
        @State private var cacheSize: Int64 = 0
        @State private var isClearingCache = false
        @State private var isLoggingOut = false
        @State private var cellularEnabled: Bool = ThumbnailNetworkPolicy.shared.cellularOptIn
        @AppStorage("syncNotificationsEnabled") private var syncNotificationsEnabled = false
        @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) private var tutorialShown: Bool = DefaultSettings
            .tutorialShown
        @AppStorage("io.cubbit.DS3Drive.thumbnailGenerateNowWarningShown")
        private var generateNowWarningShown: Bool = false
        @State private var copiedFieldId: String?

        private var account: Account? {
            ds3Authentication.account
        }

        private var tenantName: String {
            let saved = (try? SharedData.default().loadTenantNameFromPersistence()) ?? ""
            return saved.isEmpty ? "Not set" : saved
        }

        private var coordinatorURL: String {
            (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
        }

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        accountSection
                        generalSection
                        thumbnailsSection
                        updatesSection
                        onboardingSection
                        aboutSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .toolbarBackground(.hidden, for: .navigationBar)
            .alert("Sign Out", isPresented: $showLogoutAlert) {
                Button("Sign Out", role: .destructive) {
                    Task { await performLogout() }
                }
                Button("Cancel", role: .cancel) { /* dismiss */ }
            } message: {
                Text("Signing out will disconnect all drives. Your files in S3 are not affected.")
            }
            .alert("Clear Cache", isPresented: $showClearCacheAlert) {
                Button("Clear Cache", role: .destructive) {
                    Task { await performClearCache() }
                }
                Button("Cancel", role: .cancel) { /* dismiss */ }
            } message: {
                Text("This will remove all downloaded files. They will be re-downloaded when you open them.")
            }
            .alert("Generate Thumbnails", isPresented: $showGenerateNowAlert) {
                Button("Generate") {
                    generateNowWarningShown = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DarwinNotificationCenter.shared.post(name: DarwinNotificationCenter.thumbnailRenderRequest)
                }
                Button("Cancel", role: .cancel) { /* dismiss */ }
            } message: {
                Text(
                    "This will use data to generate thumbnails for all images. Thumbnails are small JPEG files (10–50 KB each)."
                )
            }
            .task {
                cacheSize = await CacheManager.calculateCacheSize()
            }
        }

        // MARK: - Account Section

        private var accountSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("ACCOUNT", systemImage: "person.crop.circle")

                VStack(spacing: 0) {
                    if let account {
                        infoRow(label: "Name", value: "\(account.firstName) \(account.lastName)")
                        divider
                        infoRow(label: "Email", value: account.emails.first?.email ?? "")
                        divider
                        infoRow(label: "Tenant ID", value: tenantName)
                        divider

                        Button {
                            copyToClipboard(coordinatorURL, fieldId: "connectionInfo")
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Connection Info")
                                    .font(.custom("Figtree-SemiBold", size: 15))
                                    .foregroundStyle(IOSColors.brandTextPrimary)

                                Spacer(minLength: 8)

                                if copiedFieldId == "connectionInfo" {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 13))
                                        Text("Copied")
                                            .font(.custom("Figtree-Medium", size: 13))
                                    }
                                    .foregroundStyle(IOSColors.brandPrimary)
                                    .transition(.opacity)
                                } else {
                                    Text(coordinatorURL)
                                        .font(.custom("Figtree-Regular", size: 13))
                                        .foregroundStyle(IOSColors.brandTextSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.7))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        divider

                        navActionRow(
                            title: "Manage Account",
                            trailing: "arrow.up.right"
                        ) {
                            if let url = URL(string: ConsoleURLs.profileURL) {
                                openURL(url)
                            }
                        }

                        divider

                        destructiveActionRow(title: isLoggingOut ? "Signing Out…" : "Sign Out") {
                            showLogoutAlert = true
                        }
                        .disabled(isLoggingOut)
                    }
                }
                .background(cardBackground)
            }
        }

        // MARK: - General Section

        private var generalSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("GENERAL", systemImage: "slider.horizontal.3")

                VStack(spacing: 0) {
                    infoRow(label: "Active Drives", value: "\(ds3DriveManager.drives.count)")

                    divider

                    HStack(alignment: .center, spacing: 12) {
                        Text("Sync Notifications")
                            .font(.custom("Figtree-SemiBold", size: 15))
                            .foregroundStyle(IOSColors.brandTextPrimary)

                        Spacer(minLength: 8)

                        Toggle("", isOn: $syncNotificationsEnabled)
                            .labelsHidden()
                            .tint(IOSColors.brandPrimary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                    divider

                    HStack(alignment: .center, spacing: 12) {
                        Text("Cache")
                            .font(.custom("Figtree-SemiBold", size: 15))
                            .foregroundStyle(IOSColors.brandTextPrimary)

                        Spacer(minLength: 8)

                        if isClearingCache {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(CacheManager.formatSize(cacheSize))
                                .font(.custom("Figtree-Regular", size: 13))
                                .foregroundStyle(IOSColors.brandTextSecondary)
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showClearCacheAlert = true
                        } label: {
                            Text("Clear")
                                .font(.custom("Figtree-SemiBold", size: 13))
                                .foregroundStyle(IOSColors.statusError)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(IOSColors.statusError.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isClearingCache)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .background(cardBackground)
            }
        }

        // MARK: - Thumbnails Section

        private var thumbnailsSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("THUMBNAILS", systemImage: "photo.on.rectangle.angled")

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if thumbnailBackfillDriver.pendingCount > 0 {
                                Text("\(thumbnailBackfillDriver.pendingCount) thumbnails pending")
                            } else {
                                Text("All thumbnails up to date")
                            }
                        }
                        .font(.custom("Figtree-SemiBold", size: 15))
                        .foregroundStyle(IOSColors.brandTextPrimary)

                        Spacer(minLength: 8)

                        if thumbnailBackfillDriver.isRunning {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)

                    divider

                    HStack(alignment: .center, spacing: 12) {
                        Text("Allow on Cellular")
                            .font(.custom("Figtree-SemiBold", size: 15))
                            .foregroundStyle(IOSColors.brandTextPrimary)

                        Spacer(minLength: 8)

                        Toggle("", isOn: $cellularEnabled)
                            .labelsHidden()
                            .tint(IOSColors.brandPrimary)
                            .onChange(of: cellularEnabled) { _, newValue in
                                ThumbnailNetworkPolicy.shared.cellularOptIn = newValue
                            }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                    divider

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if generateNowWarningShown {
                            DarwinNotificationCenter.shared.post(
                                name: DarwinNotificationCenter.thumbnailRenderRequest
                            )
                        } else {
                            showGenerateNowAlert = true
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Generate Thumbnails Now")
                                .font(.custom("Figtree-SemiBold", size: 15))
                                .foregroundStyle(IOSColors.brandPrimary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IOSColors.brandPrimary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(cardBackground)

                Text(
                    "Thumbnail generation runs while the app is open. Force-quitting the app stops background generation until next launch."
                )
                .font(.custom("Figtree-Regular", size: 12))
                .foregroundStyle(IOSColors.brandTextSecondary)
                .padding(.horizontal, 4)
            }
        }

        // MARK: - Updates Section

        private var updatesSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("UPDATES", systemImage: "arrow.down.circle")

                VStack(spacing: 0) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if updateChecker.updateAvailable {
                            openUpdateDestination()
                        } else {
                            Task { await updateChecker.checkForUpdates() }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                                Text("Update Available: \(version)")
                                    .font(.custom("Figtree-SemiBold", size: 15))
                                    .foregroundStyle(IOSColors.brandPrimary)
                            } else {
                                Text("Check for Updates")
                                    .font(.custom("Figtree-SemiBold", size: 15))
                                    .foregroundStyle(IOSColors.brandTextPrimary)
                            }

                            Spacer(minLength: 8)

                            if updateChecker.isChecking {
                                ProgressView().controlSize(.small)
                            } else if updateChecker.updateAvailable {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IOSColors.brandPrimary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(updateChecker.isChecking)

                    divider

                    infoRow(label: "Distribution", value: updateChecker.channel.displayName)
                }
                .background(cardBackground)
            }
        }

        // MARK: - Onboarding Section

        private var onboardingSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("ONBOARDING", systemImage: "play.rectangle.on.rectangle")

                VStack(spacing: 0) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        tutorialShown = false
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Show Tutorial Again")
                                .font(.custom("Figtree-SemiBold", size: 15))
                                .foregroundStyle(IOSColors.brandTextPrimary)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IOSColors.brandPrimary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(cardBackground)
            }
        }

        // MARK: - About Section

        private var aboutSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("ABOUT", systemImage: "info.circle")

                VStack(spacing: 0) {
                    infoRow(
                        label: "Version",
                        value: "v\(DefaultSettings.appVersion) (\(DefaultSettings.appBuild))"
                    )

                    divider

                    NavigationLink {
                        licensesView
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Licenses")
                                .font(.custom("Figtree-SemiBold", size: 15))
                                .foregroundStyle(IOSColors.brandTextPrimary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.7))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    divider

                    navActionRow(title: "Support", trailing: "arrow.up.right") {
                        if let url = URL(string: HelpURLs.baseURL) {
                            openURL(url)
                        }
                    }
                }
                .background(cardBackground)
            }
        }

        private var licensesView: some View {
            IOSLicensesView()
        }

        private var cardBackground: some View {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
                )
        }

        private var divider: some View {
            Rectangle()
                .fill(IOSColors.brandBorderSubtle)
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }

    // MARK: - Row Builders + Actions

    private extension IOSSettingsView {
        func sectionHeader(_ text: LocalizedStringKey, systemImage: String) -> some View {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(.custom("Figtree-Medium", size: 12))
                    .tracking(0.5)
            }
            .foregroundStyle(IOSColors.brandTextSecondary)
            .padding(.leading, 4)
        }

        func infoRow(label: LocalizedStringKey, value: String) -> some View {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.custom("Figtree-SemiBold", size: 15))
                    .foregroundStyle(IOSColors.brandTextPrimary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.custom("Figtree-Regular", size: 15))
                    .foregroundStyle(IOSColors.brandTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }

        func navActionRow(title: LocalizedStringKey, trailing: String, action: @escaping () -> Void) -> some View {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.custom("Figtree-SemiBold", size: 15))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: trailing)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IOSColors.brandPrimary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        func destructiveActionRow(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                action()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.custom("Figtree-SemiBold", size: 15))
                        .foregroundStyle(IOSColors.statusError)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        func copyToClipboard(_ value: String, fieldId: String) {
            UIPasteboard.general.string = value
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { copiedFieldId = fieldId }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { if copiedFieldId == fieldId { copiedFieldId = nil } }
            }
        }

        func openUpdateDestination() {
            switch updateChecker.channel {
            case .testFlight:
                if let url = URL(string: "itms-beta://") { UIApplication.shared.open(url) }
            case .appStore:
                if let url = URL(string: "itms-apps://apps.apple.com") { UIApplication.shared.open(url) }
            }
        }

        func performLogout() async {
            isLoggingOut = true
            try? await ds3DriveManager.cleanFileProvider()
            ds3Authentication.logout()
            isLoggingOut = false
        }

        func performClearCache() async {
            isClearingCache = true
            try? await CacheManager.clearCache()
            cacheSize = await CacheManager.calculateCacheSize()
            isClearingCache = false
        }
    }

    private struct IOSLicensesView: View {
        var body: some View {
            ScrollView {
                Text(
                    "Open Source Licenses\n\nThis application uses the following open source libraries:\n\n- Soto for AWS (Apache 2.0)\n- Swift Atomics (Apache 2.0)\n- Swift NIO (Apache 2.0)"
                )
                .font(.custom("Figtree-Regular", size: 15))
                .foregroundStyle(IOSColors.brandTextPrimary)
                .padding(20)
            }
            .background(IOSGradients.brandVerticalBackground.ignoresSafeArea())
            .navigationTitle("Licenses")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
#endif
