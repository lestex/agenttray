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
    /// The response behind `fetch()`, unparsed, for `--dump`.
    func dump() async throws -> (HTTPURLResponse, Data)
    /// Tokens by day and model from the CLI's local session logs. Blocking
    /// file reads, so call it off the main thread.
    func history() -> TokenHistory
}

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let title = "Claude"
    func fetch() async throws -> Snapshot { try await UsageAPI.fetch() }
    func dump() async throws -> (HTTPURLResponse, Data) { try await UsageAPI.perform() }
    func history() -> TokenHistory { ClaudeHistory.load() }
}

struct CodexProvider: UsageProvider {
    let id = "codex"
    let title = "Codex"
    func fetch() async throws -> Snapshot { try await CodexAPI.fetch() }
    func dump() async throws -> (HTTPURLResponse, Data) { try await CodexAPI.perform() }
    func history() -> TokenHistory { CodexHistory.load() }
}

/// The agents this build knows about, in tab order.
enum Providers {
    static let all: [any UsageProvider] = [ClaudeProvider(), CodexProvider()]

    static func named(_ id: String) -> (any UsageProvider)? {
        all.first { $0.id == id }
    }
}
