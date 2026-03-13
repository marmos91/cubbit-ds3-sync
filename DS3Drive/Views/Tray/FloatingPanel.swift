import SwiftUI
import AppKit

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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
    func show<Content: View>(_ sidePanel: SidePanel, @ViewBuilder content: () -> Content) {
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

        let hostingView = NSHostingView(rootView: wrappedContent)
        let fittingSize = hostingView.fittingSize
        let panelHeight = min(fittingSize.height, trayFrame.height)

        // Top-align with the tray window
        let origin = NSPoint(
            x: trayFrame.minX - panelWidth - gap,
            y: trayFrame.maxY - panelHeight
        )

        let rect = NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight))
        let floatingPanel = FloatingPanel(contentRect: rect)

        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight))
        floatingPanel.contentView = hostingView

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

    nonisolated deinit {
        // KVO observation is automatically invalidated when the NSKeyValueObservation is deallocated
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
