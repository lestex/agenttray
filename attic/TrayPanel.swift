import AppKit
import Combine
import SwiftUI

/// The dropdown. A borderless panel rather than an NSPopover: a popover always
/// draws its arrow on top of the status item and ends up overlapping the menu
/// bar, while a panel can be pinned directly below it the way a menu is.
///
/// The backdrop is built in AppKit, not SwiftUI: blur at the back, a darkening
/// scrim over it, the hosting view on top. Stacking these in a SwiftUI ZStack
/// does not work — an NSViewRepresentable blur draws over sibling SwiftUI
/// layers, so the scrim never lands.
@MainActor
final class TrayPanel: NSPanel {
    private weak var statusItem: NSStatusItem?
    private let hosting: NSHostingView<PanelContainer>
    private var sizeObserver: AnyCancellable?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    /// Clicking the status item resigns key first, which would otherwise close
    /// and immediately reopen the panel.
    private var lastDismiss = Date.distantPast

    private let cornerRadius: CGFloat = 12
    private let gapBelowMenuBar: CGFloat = 6
    private let screenInset: CGFloat = 8

    init(model: UsageModel) {
        hosting = NSHostingView(rootView: PanelContainer(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let scrim = ScrimView()
        for view in [scrim, hosting] {
            view.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                view.topAnchor.constraint(equalTo: blur.topAnchor),
                view.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
        }
        contentView = blur

        // The window no longer auto-sizes from a hosting controller, so follow
        // the content: an error appearing changes the panel's height.
        sizeObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isVisible else { return }
                self.sizeToContent()
            }
    }

    override var canBecomeKey: Bool { true }   // borderless panels refuse by default

    func toggle(from item: NSStatusItem) {
        if isVisible {
            dismiss()
        } else if Date().timeIntervalSince(lastDismiss) > 0.15 {
            present(from: item)
        }
    }

    func present(from item: NSStatusItem) {
        statusItem = item
        guard let button = item.button, let barWindow = button.window else { return }
        sizeToContent()

        // Bottom edge of the status item is the bottom of the menu bar.
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.minX
        if let visible = (barWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(visible.minX + screenInset, x), visible.maxX - frame.width - screenInset)
        }
        setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - gapBelowMenuBar))

        button.highlight(true)
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        startMonitoring()
    }

    func dismiss() {
        guard isVisible else { return }
        stopMonitoring()
        statusItem?.button?.highlight(false)
        orderOut(nil)
        lastDismiss = Date()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    private func sizeToContent() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        setContentSize(size)
        invalidateShadow()
    }

    // MARK: - Dismiss triggers

    private func startMonitoring() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {                          // Escape
                Task { @MainActor in self.dismiss() }
                return nil
            }
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            Task { @MainActor in NSApplication.shared.terminate(nil) }
            return nil
        }
    }

    private func stopMonitoring() {
        [outsideMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        outsideMonitor = nil
        keyMonitor = nil
    }
}

/// Darkens the blur to menu depth. A plain vibrancy blur is too light and too
/// wallpaper-coloured on its own.
private final class ScrimView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved here rather than stored: cgColor picks up the current
        // appearance, so this follows light/dark for free.
        layer?.backgroundColor = Palette.panelScrimNS.cgColor
    }
}

/// The panel's content, over the AppKit backdrop.
struct PanelContainer: View {
    @ObservedObject var model: UsageModel
    private let radius: CGFloat = 12

    var body: some View {
        PopoverView(model: model)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }
}
