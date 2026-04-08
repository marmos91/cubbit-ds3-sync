import AppKit
import DS3Lib
import os.log
import SwiftUI

struct PreferencesView: View {
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication

    var preferencesViewModel: PreferencesViewModel

    var body: some View {
        TabView {
            GeneralTab(preferencesViewModel: preferencesViewModel)
                .tabItem { Label("General", systemImage: "gear") }

            AccountTab(preferencesViewModel: preferencesViewModel)
                .tabItem { Label("Account", systemImage: "person.circle") }
                .environment(ds3DriveManager)

            SyncTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            ConnectionTab()
                .tabItem {
                    Label(
                        NSLocalizedString(
                            "preferences.tab.connection",
                            value: "Connection",
                            comment: "Preferences tab title"
                        ),
                        systemImage: "network"
                    )
                }
                .environment(ds3Authentication)

            TrashTab()
                .tabItem { Label("Trash", systemImage: "trash") }
                .environment(ds3DriveManager)
        }
        .frame(
            minWidth: 720,
            idealWidth: 760,
            maxWidth: 900,
            minHeight: 560,
            idealHeight: 600,
            maxHeight: 800
        )
        // Plan 05-18b Gap 24: force the brand backdrop to cover the whole
        // window (including any title bar safe-area), and lock the scene to
        // dark appearance so the tab bar chrome matches the brand surface.
        // Per-tab body card-wrapping (`.brandCard()`) is intentionally out
        // of scope for this plan — tracked as a follow-up.
        .background(DS3Colors.brandBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .background(WindowButtonCustomizer(hideZoom: true))
    }
}

// MARK: - Window button customizer

/// Walks up to the hosting `NSWindow` and disables the zoom (green)
/// traffic-light button. Used by the Preferences window — it isn't meant
/// to be full-screened, and the resizable size range is tight enough
/// that maximizing doesn't add value.
private struct WindowButtonCustomizer: NSViewRepresentable {
    let hideZoom: Bool

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        // `updateNSView` is called after the view is attached to the
        // window hierarchy, so `nsView.window` is reliably non-nil here.
        // A single dispatch-async from `makeNSView` was racy — if SwiftUI
        // hadn't yet flushed the view into a window, the customization
        // would silently no-op and the zoom button would stay enabled.
        // Applying from `updateNSView` (idempotently) is the safe fix.
        guard let window = nsView.window else { return }
        window.standardWindowButton(.zoomButton)?.isEnabled = !hideZoom
        if hideZoom {
            window.collectionBehavior.insert(.fullScreenNone)
        }
    }
}

#Preview {
    PreferencesView(
        preferencesViewModel: PreferencesViewModel(
            account: PreviewData.account
        )
    )
    .environment(DS3Authentication())
    .environment(
        DS3DriveManager(appStatusManager: AppStatusManager.default())
    )
}
