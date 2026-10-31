import AppKit
import Combine
import ServiceManagement

private let showsPercentageKey = "menuBarLongForm"   // old name, kept so the setting survives
private let selectedProviderKey = "selectedProvider"

/// What the app knows about one agent right now.
struct ProviderState: Equatable {
    var limits: [Limit] = []
    var extra: ExtraUsage?
    var plan: String?
    var errorMessage: String?
    var retryAt: Date?
    var lastUpdated: Date?
    var isLoading = false
    var failures = 0
    /// From the local session logs; nil until the first read lands.
    var history: TokenHistory?
    var historyReadAt: Date?
}

@MainActor
final class UsageModel: ObservableObject {
    let providers: [any UsageProvider] = Providers.all

    @Published private var states: [String: ProviderState] = [:]

    /// Which tab is showing. Also decides what the menu bar draws.
    @Published var selectedID: String = UserDefaults.standard.string(forKey: selectedProviderKey)
        ?? Providers.all.first?.id ?? "" {
        didSet { UserDefaults.standard.set(selectedID, forKey: selectedProviderKey) }
    }

    /// Swaps the menu bar gauges for labelled percentages.
    @Published var showsPercentage: Bool = UserDefaults.standard.bool(forKey: showsPercentageKey) {
        didSet { UserDefaults.standard.set(showsPercentage, forKey: showsPercentageKey) }
    }

    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var tasks: [String: Task<Void, Never>] = [:]
    /// A scheduled retry after a transient failure, one per agent.
    private var retries: [String: Task<Void, Never>] = [:]
    private var historyReads: [String: Task<Void, Never>] = [:]

    /// How often to poll the usage endpoint. The windows move slowly and the
    /// countdowns tick locally, so there is nothing to gain from polling hard —
    /// and the endpoint rate limits.
    static let pollInterval: TimeInterval = 900

    /// De-dupes triggers that can coincide — a launch right after a wake, say.
    private let freshFor: TimeInterval = 60
    private let maxBackoff: TimeInterval = 1800

    init() {
        for (id, entry) in Cache.load() {
            states[id] = ProviderState(limits: entry.snapshot.limits,
                                       extra: entry.snapshot.extra,
                                       plan: entry.snapshot.plan,
                                       lastUpdated: entry.fetchedAt)
        }
        if providers.contains(where: { $0.id == selectedID }) == false {
            selectedID = providers.first?.id ?? ""
        }
    }

    // MARK: - The selected agent

    var selected: ProviderState { states[selectedID] ?? ProviderState() }
    var limits: [Limit] { selected.limits }
    var extra: ExtraUsage? { selected.extra }
    var errorMessage: String? { selected.errorMessage }
    var isLoading: Bool { selected.isLoading }
    var plan: String? { selected.plan }
    var history: TokenHistory? { selected.history }

    /// Showing data we could not refresh — the menu flags it.
    var isStale: Bool { errorMessage != nil && !limits.isEmpty }

    /// Polls are 15 minutes apart, so seconds here were noise. An older
    /// snapshot keeps its date.
    var lastUpdatedText: String {
        guard let at = selected.lastUpdated else { return "Never updated" }
        return "Updated \(Format.clock(at, template: Calendar.current.isDateInToday(at) ? "jm" : "dMMMjm"))"
    }

    /// A backoff can be 30 seconds long, so this one keeps them.
    var retryText: String? {
        guard let retryAt = selected.retryAt, retryAt > Date() else { return nil }
        return "Retrying at \(Format.clock(retryAt, template: "jms"))."
    }

    /// Replaces the gauges in the menu bar: "!" when the last fetch failed —
    /// the cached numbers are still in the menu — and "…" on a cold start.
    var statusText: String? {
        if errorMessage != nil { return "!" }
        if limits.isEmpty { return isLoading ? "…" : "—" }
        return nil
    }

    // MARK: - Fetching

    /// Every caller is a background trigger: the launch, the poll timer, waking
    /// from sleep. Refreshes every agent, so switching tabs shows current data.
    func refresh() {
        for provider in providers { refresh(provider) }
        readHistory()
    }

    /// Re-reads every agent's session logs off the main thread. Cheap — only
    /// logs touched in the last week are opened — so it also runs each time
    /// the menu opens, to keep "Today" current between polls.
    func readHistory() {
        for provider in providers {
            let id = provider.id
            guard historyReads[id] == nil else { continue }
            if let at = states[id]?.historyReadAt, Date().timeIntervalSince(at) < 10 { continue }
            historyReads[id] = Task { [weak self] in
                let history = await Task.detached(priority: .utility) { provider.history() }.value
                guard let self else { return }
                self.historyReads[id] = nil
                if self.states[id]?.history != history {
                    self.states[id, default: ProviderState()].history = history
                }
                self.states[id, default: ProviderState()].historyReadAt = Date()
            }
        }
    }

    private func refresh(_ provider: any UsageProvider) {
        let id = provider.id
        guard tasks[id] == nil else { return }
        let state = states[id] ?? ProviderState()
        if let retryAt = state.retryAt, retryAt > Date() { return }
        if let at = state.lastUpdated, Date().timeIntervalSince(at) < freshFor { return }

        states[id, default: ProviderState()].isLoading = true
        tasks[id] = Task { [weak self] in
            defer { Task { @MainActor in
                self?.tasks[id] = nil
                self?.states[id, default: ProviderState()].isLoading = false
            } }
            do {
                let snapshot = try await provider.fetch()
                await MainActor.run { self?.apply(snapshot, for: id) }
            } catch {
                await MainActor.run { self?.failed(with: error, for: id) }
            }
        }
    }

    func apply(_ snapshot: Snapshot, for id: String) {
        let now = Date()
        retries[id]?.cancel()
        retries[id] = nil
        var state = states[id] ?? ProviderState()
        state.limits = snapshot.limits
        state.extra = snapshot.extra
        state.plan = snapshot.plan
        state.lastUpdated = now
        state.errorMessage = nil
        state.retryAt = nil
        state.failures = 0
        states[id] = state
        var cached = Cache.load()
        cached[id] = Cache.Entry(fetchedAt: now, snapshot: snapshot)
        Cache.save(cached)
    }

    private func failed(with error: Error, for id: String) {
        var state = states[id] ?? ProviderState()
        state.errorMessage = error.localizedDescription
        state.failures += 1
        let backoff = min(maxBackoff, 30 * pow(2, Double(state.failures - 1)))
        if case UsageError.rateLimited(let retryAfter) = error {
            // Honour Retry-After when the server sends one, otherwise back off
            // 30 s, 60 s, 120 s … up to half an hour. Requests made while the
            // limit is in force may well be what keeps it in force.
            state.retryAt = Date().addingTimeInterval(retryAfter ?? backoff)
        } else if Self.isTransient(error) {
            // Typically a wake from sleep that beat the network back. Waiting
            // for the next poll would leave the "!" up for 15 minutes, so try
            // again on the same 30 s, 60 s, 120 s … schedule.
            let retryAt = Date().addingTimeInterval(min(backoff, Self.pollInterval))
            state.retryAt = retryAt
            scheduleRetry(for: id, at: retryAt)
        }
        if state.lastUpdated == nil { state.limits = []; state.extra = nil }
        states[id] = state
    }

    private func scheduleRetry(for id: String, at date: Date) {
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.retries[id] = nil
            if let provider = self.providers.first(where: { $0.id == id }) { self.refresh(provider) }
        }
    }

    /// Failures that say nothing about the login or the payload, and are likely
    /// to clear by themselves: no network yet, a timeout, a server-side error.
    private static func isTransient(_ error: Error) -> Bool {
        if case UsageError.http(let code) = error { return code >= 500 }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    // MARK: - Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("AgentTray: login item change failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
