import AppKit
import DS3Lib
import FileProvider
import os.log
import SwiftUI

// MARK: - GearMenuButton

/// `NSButton` wrapped as a SwiftUI view so the gear menu can pop a real
/// `NSMenu` instead of relying on SwiftUI's `Menu`. SwiftUI Menu inside the
/// tray's `MenuBarExtra` window has been unreliable across macOS Sequoia
/// updates — the popover sometimes never presents because of hit-test
/// races with the floating Recent Files panel and the borderless button
/// label's tight intrinsic frame. Going through AppKit primitives bypasses
/// every SwiftUI Menu quirk.
struct GearMenuButton: NSViewRepresentable {
    var menuBuilder: () -> NSMenu
    var onClick: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = ""
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))
        button.focusRingType = .none
        // SwiftUI sizes NSViewRepresentable hosts to 0×0 unless the NSView
        // declares an intrinsic size or constraints. Without these the
        // visible icon renders but the click target has zero area.
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        context.coordinator.menuBuilder = menuBuilder
        context.coordinator.onClick = onClick
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.menuBuilder = menuBuilder
        context.coordinator.onClick = onClick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        var menuBuilder: (() -> NSMenu)?
        var onClick: (() -> Void)?

        @objc
        func buttonClicked(_ sender: NSButton) {
            onClick?()
            guard let menu = menuBuilder?() else { return }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }
    }
}

// MARK: - BlockMenuItem

/// `NSMenuItem` subclass that wires its `action` selector to a closure,
/// removing the need to define `@objc` action methods on a target class
/// for each menu item.
@MainActor
final class BlockMenuItem: NSMenuItem {
    private let block: @MainActor () -> Void

    init(title: String, systemImage: String? = nil, block: @escaping @MainActor () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        if let systemImage {
            self.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc
    private func invoke() {
        block()
    }
}

// MARK: - TrayDriveGearMenu

/// Builds the per-drive `NSMenu` consumed by `GearMenuButton`. Lives in a
/// helper namespace so the giant menu construction stays out of the
/// `TrayDriveRowView` body and the file passes SwiftLint length limits.
enum TrayDriveGearMenu {
    @MainActor
    static func build(
        driveViewModel: DS3DriveViewModel,
        ds3DriveManager: DS3DriveManager,
        openURL: OpenURLAction,
        logger: Logger
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let driveId = driveViewModel.drive.id
        let isPaused = driveViewModel.driveStatus == .paused
        let s3Path = buildS3Path(for: driveViewModel)

        addAction(menu: menu, title: "Disconnect", systemImage: "eject") {
            Task {
                do {
                    try await ds3DriveManager.disconnect(driveWithId: driveId)
                } catch {
                    logger.error("Error disconnecting drive: \(error.localizedDescription)")
                }
            }
        }

        addAction(menu: menu, title: "View in Finder", systemImage: "folder") {
            Task {
                do {
                    try await driveViewModel.openFinder()
                } catch {
                    // Finder open failure is non-critical
                }
            }
        }

        addAction(menu: menu, title: "View in web console", systemImage: "globe") {
            if let consoleURL = driveViewModel.consoleURL() {
                openURL(consoleURL)
            }
        }

        addAction(menu: menu, title: "Refresh", systemImage: "arrow.clockwise") {
            Task {
                do {
                    try await driveViewModel.reEnumerate()
                } catch {
                    logger.error("Error refreshing drive: \(error.localizedDescription)")
                }
            }
        }

        addAction(menu: menu, title: "Reset Sync", systemImage: "arrow.counterclockwise") {
            Task {
                do {
                    try await driveViewModel.resetSync()
                } catch {
                    logger.error("Error resetting sync: \(error.localizedDescription)")
                }
            }
        }

        addAction(menu: menu, title: "Empty Trash", systemImage: "trash.slash") {
            do {
                try SharedData.default().setEmptyTrashRequest(forDrive: driveId, requested: true)
                logger.info("Empty trash requested for drive \(driveId)")
            } catch {
                logger.error("Error requesting empty trash: \(error.localizedDescription)")
            }
        }

        menu.addItem(.separator())

        addAction(
            menu: menu,
            title: isPaused ? "Resume" : "Pause",
            systemImage: isPaused ? "play" : "pause"
        ) {
            togglePause(
                driveViewModel: driveViewModel,
                ds3DriveManager: ds3DriveManager,
                logger: logger
            )
        }

        addAction(menu: menu, title: "Copy S3 Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s3Path, forType: .string)
        }

        return menu
    }

    // MARK: - Helpers

    @MainActor
    private static func addAction(
        menu: NSMenu,
        title: String,
        systemImage: String,
        block: @escaping @MainActor () -> Void
    ) {
        let item = BlockMenuItem(
            title: NSLocalizedString(title, comment: "Drive menu \(title)"),
            systemImage: systemImage,
            block: block
        )
        menu.addItem(item)
    }

    @MainActor
    private static func buildS3Path(for viewModel: DS3DriveViewModel) -> String {
        var path = viewModel.drive.syncAnchor.bucket.name
        if let prefix = viewModel.drive.syncAnchor.prefix, !prefix.isEmpty {
            path += "/\(prefix)"
        }
        return path
    }

    @MainActor
    private static func togglePause(
        driveViewModel: DS3DriveViewModel,
        ds3DriveManager: DS3DriveManager,
        logger: Logger
    ) {
        let driveId = driveViewModel.drive.id
        let isPaused = driveViewModel.driveStatus == .paused
        do {
            try SharedData.default().setDrivePaused(driveId, paused: !isPaused)

            if isPaused {
                driveViewModel.driveStatus = .sync
                ds3DriveManager.notifyDriveResumedFromUI(driveId: driveId)

                let domain = driveViewModel.fileProviderDomain()
                let fpManager = NSFileProviderManager(for: domain)
                Task {
                    try? await fpManager?.signalEnumerator(for: .rootContainer)
                }
            } else {
                driveViewModel.driveStatus = .paused
                ds3DriveManager.notifyDrivePausedFromUI(driveId: driveId)
            }
        } catch {
            logger.error("Error toggling pause state: \(error.localizedDescription)")
        }
    }
}
