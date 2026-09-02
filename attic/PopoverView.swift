import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)

            if let error = model.errorMessage, model.limits.isEmpty {
                errorBlock(error)
            } else {
                // One second tick keeps the countdowns live while the popover is open.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.limits) { limit in
                            LimitRow(limit: limit, now: context.date)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }

            if let extra = model.extra {
                Divider().padding(.horizontal, 14)
                extraRow(extra)
            }

            Divider().padding(.horizontal, 14)
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AgentTray").font(.system(size: 15, weight: .bold))
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .help("Refreshing")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Can't read usage", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.danger)
            Text([message, model.retryText].compactMap { $0 }.joined(separator: " "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func extraRow(_ extra: ExtraUsage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard").font(.system(size: 10))
            Text("Extra usage").font(.system(size: 11, weight: .medium))
            Spacer()
            Text("\(extra.used) / \(extra.limit)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Format.percent(extra.utilization))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.level(extra.utilization))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Menu-style rows: icon column, label, shortcut on the right.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if model.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.warn)
                }
                Text(model.lastUpdatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .help([model.errorMessage, model.retryText].compactMap { $0 }.joined(separator: " "))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            MenuRow(icon: model.longForm ? "checkmark.square.fill" : "square",
                    title: "Long form",
                    action: { model.longForm.toggle() })
            MenuRow(icon: model.launchAtLogin ? "checkmark.square.fill" : "square",
                    title: "Open at login",
                    action: { model.setLaunchAtLogin(!model.launchAtLogin) })

            Divider().padding(.horizontal, 14).padding(.vertical, 5)

            MenuRow(icon: "power", title: "Quit", shortcut: "⌘Q",
                    action: { NSApplication.shared.terminate(nil) })
        }
        .padding(.bottom, 8)
    }
}

/// One row of the footer menu, highlighting under the pointer like a real menu.
private struct MenuRow: View {
    let icon: String
    let title: String
    var shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 14, alignment: .center)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 12)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0))
        )
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

private struct LimitRow: View {
    let limit: Limit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.system(size: 13, weight: .bold))
                Spacer()
                Text(Format.percent(limit.utilization))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.level(limit.utilization))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule()
                        .fill(Palette.level(limit.utilization))
                        .frame(width: max(5, geo.size.width * limit.utilization / 100))
                }
            }
            .frame(height: 7)

            Text(limit.resetsAt.map { Format.countdown(to: $0, now: now) }
                 ?? "Reset not reported by the API")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
