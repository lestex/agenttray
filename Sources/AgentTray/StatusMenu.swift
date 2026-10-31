import AppKit
import Combine

/// The dropdown, as a real NSMenu. Every hand-built panel we tried had to
/// reproduce menu chrome — blur, scrim, corner radius, shadow — and never quite
/// matched. A menu simply is that chrome, drawn by the system.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: UsageModel
    let menu = NSMenu()

    private var isOpen = false
    /// What the rows below the tabs were built from, so a model change that
    /// lands while the menu is open rebuilds them only if they would differ.
    private var shown: Content?
    private var changes: AnyCancellable?

    private struct Content: Equatable {
        let id: String
        let limits: [Limit]
        let extra: ExtraUsage?
        let plan: String?
        let history: TokenHistory?
        let error: String?
        let updated: String
    }

    init(model: UsageModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        // The main queue, not RunLoop.main: it is serviced while the menu tracks.
        changes = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                // objectWillChange fires before the values land.
                DispatchQueue.main.async { self?.rebuildIfChanged() }
            }
    }

    /// How many items sit above the agent's own rows: just the tabs. The plan
    /// and the separator below it belong to the selected agent.
    private let headerItems = 1

    /// Rebuilt on every open: the countdowns move, and a menu is short-lived.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(tabs())
        appendBody(to: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        // Today's tokens move between polls; the rows follow when the read lands.
        model.readHistory()
    }

    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    /// Swapping tabs replaces everything below them, leaving the menu open. The
    /// tab row itself stays put — it is the view whose click we are handling.
    private func select(_ index: Int) {
        guard index >= 0, index < model.providers.count else { return }
        model.selectedID = model.providers[index].id
        rebuildBody()
    }

    private func rebuildIfChanged() {
        guard isOpen, content != shown else { return }
        rebuildBody()
    }

    private func rebuildBody() {
        while menu.numberOfItems > headerItems { menu.removeItem(at: headerItems) }
        appendBody(to: menu)
    }

    private var content: Content {
        Content(id: model.selectedID, limits: model.limits, extra: model.extra, plan: model.plan,
                history: model.history, error: model.errorMessage, updated: model.lastUpdatedText)
    }

    /// A small-caps label above a group of rows.
    private func section(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = MenuTextView(text.uppercased(),
                                 font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                                 color: .secondaryLabelColor)
        return item
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
        shown = content

        if let plan = model.plan {
            menu.addItem(section(Format.plan(plan)))
        }
        menu.addItem(divider())
        menu.addItem(section("Limits"))

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

        if let history = model.history {
            appendHistory(history, to: menu)
        }

        menu.addItem(divider())

        let status = model.isStale
            ? "\(model.lastUpdatedText) — \([model.errorMessage, model.retryText].compactMap { $0 }.joined(separator: " "))"
            : model.lastUpdatedText
        menu.addItem(caption(status))

        menu.addItem(toggle("Show percentage", isOn: model.showsPercentage,
                            action: #selector(toggleShowsPercentage)))
        menu.addItem(toggle("Open at login", isOn: model.launchAtLogin, action: #selector(toggleLaunchAtLogin)))

        menu.addItem(divider())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Tokens by day, then by model, both over the same week of local logs.
    private func appendHistory(_ history: TokenHistory, to menu: NSMenu) {
        menu.addItem(divider())
        menu.addItem(section("Tokens by day"))
        let calendar = Calendar.current
        let dayLabels = history.days.map {
            calendar.isDateInToday($0.start) ? "Today" : Format.clock($0.start, template: "EEE")
        }
        let dayWidth = BarRowView.labelWidth(for: dayLabels)
        let busiestDay = history.days.map(\.tokens).max() ?? 0
        for (day, label) in zip(history.days, dayLabels) {
            menu.addItem(bar(label, tokens: day.tokens, of: busiestDay, labelWidth: dayWidth,
                             emphasized: label == "Today"))
        }

        menu.addItem(divider())
        menu.addItem(section("Tokens by model · \(TokenHistory.dayCount) days"))
        guard !history.models.isEmpty else {
            menu.addItem(caption("Nothing in the last \(TokenHistory.dayCount) days"))
            return
        }
        let modelWidth = BarRowView.labelWidth(for: history.models.map(\.name))
        let busiestModel = history.models.first?.tokens ?? 0
        for model in history.models {
            menu.addItem(bar(model.name, tokens: model.tokens, of: busiestModel, labelWidth: modelWidth))
        }
    }

    // MARK: - Items

    private func divider() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = SeparatorView()
        return item
    }

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

    private func bar(_ label: String, tokens: Int, of busiest: Int, labelWidth: CGFloat,
                     emphasized: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = BarRowView(label: label, value: Format.tokens(tokens),
                               fraction: busiest > 0 ? Double(tokens) / Double(busiest) : 0,
                               labelWidth: labelWidth, emphasized: emphasized)
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
