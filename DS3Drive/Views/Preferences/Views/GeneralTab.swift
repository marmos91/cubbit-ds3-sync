import DS3Lib
import SwiftUI

struct GeneralTab: View {
    @AppStorage(DefaultSettings.UserDefaultsKeys.loginItemSet) var loginItemSet: Bool = DefaultSettings.loginItemSet
    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var startAtLogin: Bool = DefaultSettings.appIsLoginItem

    var preferencesViewModel: PreferencesViewModel

    /// Cached `RelativeDateTimeFormatter`. The class is comparatively
    /// expensive to construct (CFCalendar / CFLocale lookups) and this
    /// helper is invoked from SwiftUI body re-evaluations, so reuse a
    /// single instance instead of allocating per call.
    private static let lastCheckedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Shared "Last checked: …" subtitle used by the updates section.
    /// Renders a relative timestamp (e.g. "2 minutes ago") when a check has happened,
    /// or "Never" when there is no `lastCheckDate` yet.
    static func lastCheckedSubtitle(for lastCheckDate: Date?) -> String {
        guard let lastCheckDate else {
            return NSLocalizedString("updates.never", value: "Last checked: Never", comment: "Never checked")
        }
        let relative = lastCheckedFormatter.localizedString(for: lastCheckDate, relativeTo: Date())
        return String(
            format: NSLocalizedString(
                "updates.lastChecked",
                value: "Last checked: %@",
                comment: "Last update check timestamp"
            ),
            relative
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $startAtLogin) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Start DS3 Drive at login")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Keep DS3 Drive running in the background so your drives stay synchronized.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
                .onChange(of: self.startAtLogin) {
                    self.preferencesViewModel.setStartAtLogin(self.startAtLogin)
                    self.loginItemSet = true
                }
            } header: {
                Text("Startup")
                    .font(DS3Typography.caption)
            }

            Section {
                Toggle(isOn: .constant(true)) {
                    VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                        Text("Show sync notifications")
                            .font(DS3Typography.body)
                            .foregroundStyle(DS3Colors.primaryText)

                        Text("Display notifications for sync events such as conflicts and errors.")
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.secondaryText)
                    }
                }
            } header: {
                Text("Notifications")
                    .font(DS3Typography.caption)
            }

            UpdateSection()

            Section {
                Button {
                    // Explicit `openWindow` is required: the main scene is
                    // gated on `!tutorialShown`, but flipping the flag alone
                    // has no effect if the window was previously closed.
                    tutorialShown = false
                    openWindow(id: "io.cubbit.DS3Drive.main")
                    dismissWindow(id: "io.cubbit.DS3Drive.preferences")
                } label: {
                    HStack(spacing: DS3Spacing.sm) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .foregroundStyle(DS3Colors.brandPrimary)
                        VStack(alignment: .leading, spacing: DS3Spacing.xs) {
                            Text("Show Tutorial Again")
                                .font(DS3Typography.body)
                                .foregroundStyle(DS3Colors.primaryText)
                            Text("Replay the onboarding walkthrough.")
                                .font(DS3Typography.caption)
                                .foregroundStyle(DS3Colors.secondaryText)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Onboarding")
                    .font(DS3Typography.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(DS3Colors.brandBackground)
        .padding(DS3Spacing.lg)
    }
}

#Preview {
    GeneralTab(
        preferencesViewModel: PreferencesViewModel(
            account: PreviewData.account
        )
    )
    .environment(UpdateManager())
    .frame(width: 800, height: 600)
}
