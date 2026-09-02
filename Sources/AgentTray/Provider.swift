import Foundation

/// An agent whose usage the app can read. Everything above this protocol works
/// from a Snapshot of named windows, so adding an agent means adding a fetcher
/// — not touching the menu, the menu bar or the cache.
protocol UsageProvider: Sendable {
    /// Stable key: used in the cache and in the remembered tab selection.
    var id: String { get }
    /// Tab label.
    var title: String { get }
    func fetch() async throws -> Snapshot
}

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let title = "Claude"
    func fetch() async throws -> Snapshot { try await UsageAPI.fetch() }
}

/// The agents this build knows about, in tab order.
enum Providers {
    static let all: [any UsageProvider] = [ClaudeProvider()]
}
