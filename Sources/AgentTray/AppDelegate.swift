import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenu!
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// How often to poll the usage endpoint. The windows move slowly and the
    /// countdowns tick locally, so there is nothing to gain from polling hard —
    /// and the endpoint rate limits.
    private let pollInterval: TimeInterval = 900

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(withText: "…")
        statusItem.button?.imagePosition = .imageOnly
        statusMenu = StatusMenu(model: model)
        statusItem.menu = statusMenu.menu

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.renderStatusItem() }
            .store(in: &cancellables)

        // Redraw when the menu bar flips between light and dark.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(renderStatusItem),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Draw once from whatever the cache held: if it is fresh enough that
        // refresh() skips the network, no change is published and the status
        // item would sit on its placeholder forever.
        renderStatusItem()

        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
    }

    @objc private func wokeUp() { model.refresh() }

    @objc private func renderStatusItem() {
        // objectWillChange fires before the values land, so read them next tick.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            button.image = StatusIcon.image(for: self.model.limits,
                                            extra: self.model.extra,
                                            showsPercentage: self.model.showsPercentage,
                                            status: self.model.statusText)
            button.toolTip = self.summaryTooltip
        }
    }

    /// Spelled out for the bars-only layout, where the numbers aren't on screen.
    private var summaryTooltip: String {
        var lines = model.limits.map { "\($0.title): \(Format.percent($0.utilization))" }
        if let extra = model.extra {
            lines.append("Extra usage: \(Format.percent(extra.utilization)) (\(extra.used) / \(extra.limit))")
        }
        lines.append(model.errorMessage.map { "\($0) \(model.retryText ?? "")" } ?? model.lastUpdatedText)
        return lines.joined(separator: "\n")
    }
}
