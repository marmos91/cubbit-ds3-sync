import AppKit
import SwiftUI

// MARK: - SidePanel

/// Represents which side panel is currently displayed.
enum SidePanel: Equatable {
    case recentFiles(driveId: UUID)
    case connectionInfo
}

// MARK: - FloatingPanel

/// A non-activating, borderless NSPanel for displaying side content next to the tray menu.
final class FloatingPanel: NSPanel {
    /// Called when the mouse enters or exits the panel content area.
    var onMouseInsideChanged: ((Bool) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool {
        false
    }
    override var canBecomeMain: Bool {
        false
    }

    /// Installs a tracking area on the content view to detect mouse enter/exit.
    func installTrackingArea() {
        guard let contentView else { return }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseInsideChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseInsideChanged?(false)
    }
}

// MARK: - FloatingPanelManager

/// Manages a floating side panel positioned to the left of the tray menu window.
@MainActor @Observable
final class FloatingPanelManager {
    private var panel: FloatingPanel?
    private(set) var activePanel: SidePanel?
    private weak var trayWindow: NSWindow?
    private var visibilityObservation: NSKeyValueObservation?
    private var dismissTimer: Timer?
    /// Whether the mouse is currently inside the floating panel.
    private var mouseInsidePanel = false

    /// How long to wait after hover-out before dismissing (allows crossing the gap).
    private static let dismissDelay: TimeInterval = 0.15

    /// Registers the tray window reference for positioning and auto-dismiss.
    func setTrayWindow(_ window: NSWindow?) {
        guard window !== trayWindow else { return }
        trayWindow = window

        visibilityObservation?.invalidate()
        visibilityObservation = window?.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            if change.newValue == false {
                Task { @MainActor in
                    self?.dismiss()
                }
            }
        }
    }

    /// Shows a floating panel with the given SwiftUI content, positioned to the left of the tray window.
    /// - Parameter anchorScreenFrame: Optional screen-coordinate rect of the trigger element (e.g. drive row).
    ///   When provided, the panel's top edge aligns with the anchor's top edge and extends downward.
    func show(_ sidePanel: SidePanel, anchorScreenFrame: NSRect? = nil, @ViewBuilder content: () -> some View) {
        cancelDismissTimer()
        dismiss()

        guard let trayFrame = trayWindow?.frame else { return }

        let panelWidth: CGFloat = 280
        let gap: CGFloat = 4

        // Size to content, capped at the tray window height
        let wrappedContent = content()
            .frame(width: panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        let hostingController = NSHostingController(rootView: wrappedContent)
        let fittingSize = hostingController.view.fittingSize
        let panelHeight = min(fittingSize.height, trayFrame.height)

        // Position panel: prefer left of tray, flip to right if off-screen
        let screenFrame = trayWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferredX = trayFrame.minX - panelWidth - gap
        let rightX = min(trayFrame.maxX + gap, screenFrame.maxX - panelWidth)
        let panelX = preferredX >= screenFrame.minX ? preferredX : rightX

        // Vertical position: anchor to drive row top if provided, otherwise tray top.
        // Panel extends downward from the anchor point, clamped to screen bounds.
        let topY = anchorScreenFrame?.maxY ?? trayFrame.maxY
        let originY = max(screenFrame.minY, topY - panelHeight)

        let origin = NSPoint(
            x: panelX,
            y: originY
        )

        let rect = NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight))
        let floatingPanel = FloatingPanel(contentRect: rect)

        floatingPanel.contentViewController = hostingController

        floatingPanel.onMouseInsideChanged = { [weak self] inside in
            Task { @MainActor in
                self?.handlePanelHover(inside)
            }
        }
        floatingPanel.installTrackingArea()

        floatingPanel.orderFront(nil)
        self.panel = floatingPanel
        self.activePanel = sidePanel
        self.mouseInsidePanel = false
    }

    /// Called when the mouse leaves the drive row in the tray.
    func scheduleDismiss() {
        guard !mouseInsidePanel else { return }
        cancelDismissTimer()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.dismissDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    /// Called when the mouse re-enters the drive row or the floating panel.
    func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// Dismisses the current floating panel immediately.
    func dismiss() {
        cancelDismissTimer()
        panel?.orderOut(nil)
        panel = nil
        activePanel = nil
        mouseInsidePanel = false
    }

    // MARK: - Private

    private func handlePanelHover(_ inside: Bool) {
        mouseInsidePanel = inside
        if inside {
            cancelDismissTimer()
        } else {
            scheduleDismiss()
        }
    }
}

// MARK: - WindowAccessor

/// An invisible NSViewRepresentable that captures the enclosing NSWindow reference.
struct WindowAccessor: NSViewRepresentable {
    @MainActor let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

// MARK: - ScreenFrameReader

/// An invisible NSViewRepresentable that reports its frame in screen coordinates.
struct ScreenFrameReader: NSViewRepresentable {
    @MainActor let onChange: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let frameInWindow = view.convert(view.bounds, to: nil)
            onChange(window.convertToScreen(frameInWindow))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let frameInWindow = nsView.convert(nsView.bounds, to: nil)
            onChange(window.convertToScreen(frameInWindow))
        }
    }
}
