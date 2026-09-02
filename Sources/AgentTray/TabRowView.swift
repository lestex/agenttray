import AppKit

/// The agent picker at the top of the menu. A menu item's view handles its own
/// events, so the segmented control works inside the open menu — picking a tab
/// swaps the rows below it without closing.
final class TabRowView: NSView {
    private let onSelect: (Int) -> Void
    private let control = NSSegmentedControl()

    init(titles: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 32))
        autoresizingMask = [.width]

        control.segmentCount = titles.count
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        control.trackingMode = .selectOne
        for (index, title) in titles.enumerated() {
            control.setLabel(title, forSegment: index)
            control.setWidth(0, forSegment: index)   // share the width evenly
        }
        control.selectedSegment = selected
        control.target = self
        control.action = #selector(picked)
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)

        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leftInset - 1),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.rightInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func picked() {
        onSelect(control.selectedSegment)
    }
}
