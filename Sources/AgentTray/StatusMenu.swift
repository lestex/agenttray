import AppKit

/// The dropdown, as a real NSMenu. Every hand-built panel we tried had to
/// reproduce menu chrome — blur, scrim, corner radius, shadow — and never quite
/// matched. A menu simply is that chrome, drawn by the system.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: UsageModel
    let menu = NSMenu()

    init(model: UsageModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// How many items sit above the agent's own rows: the tabs and a separator.
    private let headerItems = 2

    /// Rebuilt on every open: the countdowns move, and a menu is short-lived.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(tabs())
        menu.addItem(.separator())
        appendBody(to: menu)
    }

    /// Swapping tabs replaces everything below them, leaving the menu open. The
    /// tab row itself stays put — it is the view whose click we are handling.
    private func select(_ index: Int) {
        guard index >= 0, index < model.providers.count else { return }
        model.selectedID = model.providers[index].id
        while menu.numberOfItems > headerItems { menu.removeItem(at: headerItems) }
        appendBody(to: menu)
    }

    private func tabs() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let selected = model.providers.firstIndex { $0.id == model.selectedID } ?? 0
        item.view = TabRowView(titles: model.providers.map(\.title),
                               selected: selected) { [weak self] in self?.select($0) }
        return item
    }

    private func appendBody(to menu: NSMenu) {
        if let error = model.errorMessage, model.limits.isEmpty {
            menu.addItem(caption("Can't read usage", detail: [error, model.retryText]
                .compactMap { $0 }.joined(separator: " ")))
        }

        for limit in model.limits {
            menu.addItem(gauge(limit.title,
                               percent: limit.utilization,
                               detail: limit.resetsAt.map { Format.countdown(to: $0) }
                                   ?? "Reset not reported by the API"))
        }

        if let extra = model.extra {
            menu.addItem(gauge("Extra usage",
                               percent: extra.utilization,
                               detail: "\(extra.used) of \(extra.limit)",
                               detailOnRight: true))
        }

        menu.addItem(.separator())

        let status = model.isStale
            ? "\(model.lastUpdatedText) — \([model.errorMessage, model.retryText].compactMap { $0 }.joined(separator: " "))"
            : model.lastUpdatedText
        menu.addItem(caption(status))

        menu.addItem(toggle("Show percentage", isOn: model.showsPercentage,
                            action: #selector(toggleShowsPercentage)))
        menu.addItem(toggle("Open at login", isOn: model.launchAtLogin, action: #selector(toggleLaunchAtLogin)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Items

    /// A window: title and percentage, a bar, and the reset time.
    private func gauge(_ title: String, percent: Double, detail: String,
                       detailOnRight: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let row = GaugeRowView(title: title, percent: percent, detail: detail,
                               detailOnRight: detailOnRight)
        row.setFrameSize(NSSize(width: row.frame.width, height: GaugeRowView.height()))
        item.view = row
        return item
    }

    private func caption(_ text: String, detail: String? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let string = NSMutableAttributedString(
            string: detail == nil ? text : "\(text)\n",
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        if let detail {
            string.append(NSAttributedString(
                string: detail,
                attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        item.attributedTitle = string
        return item
    }

    private func toggle(_ title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func toggleShowsPercentage() { model.showsPercentage.toggle() }
    @objc private func toggleLaunchAtLogin() { model.setLaunchAtLogin(!model.launchAtLogin) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
