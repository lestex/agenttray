import AppKit
import Combine
import ServiceManagement

private let showsPercentageKey = "menuBarLongForm"   // old name, kept so the setting survives
private let selectedProviderKey = "selectedProvider"

/// What the app knows about one agent right now.
struct ProviderState: Equatable {
    var limits: [Limit] = []
    var extra: ExtraUsage?
    var errorMessage: String?
    var retryAt: Date?
    var lastUpdated: Date?
    var isLoading = false
    var failures = 0
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

    /// De-dupes triggers that can coincide — a launch right after a wake, say.
    private let freshFor: TimeInterval = 60
    private let maxBackoff: TimeInterval = 1800

    init() {
        for (id, entry) in Cache.load() {
            states[id] = ProviderState(limits: entry.snapshot.limits,
                                       extra: entry.snapshot.extra,
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

    /// Showing data we could not refresh — the menu flags it.
    var isStale: Bool { errorMessage != nil && !limits.isEmpty }

    var lastUpdatedText: String {
        guard let at = selected.lastUpdated else { return "Never updated" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(at) ? "HH:mm:ss" : "d MMM HH:mm"
        return "Updated \(f.string(from: at))"
    }

    var retryText: String? {
        guard let retryAt = selected.retryAt, retryAt > Date() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "Retrying at \(f.string(from: retryAt))."
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
        states[id] = ProviderState(limits: snapshot.limits, extra: snapshot.extra, lastUpdated: now)
        var cached = Cache.load()
        cached[id] = Cache.Entry(fetchedAt: now, snapshot: snapshot)
        Cache.save(cached)
    }

    private func failed(with error: Error, for id: String) {
        var state = states[id] ?? ProviderState()
        state.errorMessage = error.localizedDescription
        state.failures += 1
        if case UsageError.rateLimited(let retryAfter) = error {
            // Honour Retry-After when the server sends one, otherwise back off
            // 30 s, 60 s, 120 s … up to half an hour. Requests made while the
            // limit is in force may well be what keeps it in force.
            let backoff = retryAfter ?? min(maxBackoff, 30 * pow(2, Double(state.failures - 1)))
            state.retryAt = Date().addingTimeInterval(backoff)
        }
        if state.lastUpdated == nil { state.limits = []; state.extra = nil }
        states[id] = state
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
