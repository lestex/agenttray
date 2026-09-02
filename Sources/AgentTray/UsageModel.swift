import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Model

/// Old name, kept so an existing preference survives the rename.
private let showsPercentageKey = "menuBarLongForm"

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var limits: [Limit] = []
    @Published private(set) var extra: ExtraUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var retryAt: Date?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Swaps the menu bar gauges for labelled percentages.
    @Published var showsPercentage: Bool = UserDefaults.standard.bool(forKey: showsPercentageKey) {
        didSet { UserDefaults.standard.set(showsPercentage, forKey: showsPercentageKey) }
    }

    /// Showing data we could not refresh — the panel flags it.
    var isStale: Bool { errorMessage != nil && !limits.isEmpty }

    init() {
        if let cached = Cache.load() {
            limits = cached.snapshot.limits
            extra = cached.snapshot.extra
            lastUpdated = cached.fetchedAt
        }
    }

    var lastUpdatedText: String {
        guard let lastUpdated else { return "Never updated" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(lastUpdated) ? "HH:mm:ss" : "d MMM HH:mm"
        return "Updated \(f.string(from: lastUpdated))"
    }

    /// Replaces the gauges in the menu bar: "!" when the last fetch failed —
    /// the cached numbers are still in the panel — and "…" on a cold start.
    var statusText: String? {
        if errorMessage != nil { return "!" }
        if limits.isEmpty { return isLoading ? "…" : "—" }
        return nil
    }

    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    /// De-dupes triggers that can coincide — a launch right after a wake, say.
    private let freshFor: TimeInterval = 60
    private let maxBackoff: TimeInterval = 1800

    func apply(_ snapshot: Snapshot) {
        let now = Date()
        limits = snapshot.limits
        extra = snapshot.extra
        errorMessage = nil
        retryAt = nil
        lastUpdated = now
        consecutiveFailures = 0
        Cache.save(snapshot, fetchedAt: now)
    }

    private func failed(with error: Error) {
        errorMessage = error.localizedDescription
        consecutiveFailures += 1
        if case UsageError.rateLimited(let retryAfter) = error {
            // Honour Retry-After when the server sends one, otherwise back off
            // 30 s, 60 s, 120 s … up to half an hour. Requests made while the
            // limit is in force may well be what keeps it in force.
            let backoff = retryAfter ?? min(maxBackoff, 30 * pow(2, Double(consecutiveFailures - 1)))
            retryAt = Date().addingTimeInterval(backoff)
        }
        if lastUpdated == nil { limits = []; extra = nil }
    }

    var retryText: String? {
        guard let retryAt, retryAt > Date() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "Retrying at \(f.string(from: retryAt))."
    }

    /// Every caller is a background trigger — the launch, the poll timer, waking
    /// from sleep, opening the panel — so both guards always apply.
    func refresh() {
        guard task == nil else { return }
        if let retryAt, retryAt > Date() { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < freshFor { return }
        isLoading = true
        task = Task { [weak self] in
            defer { Task { @MainActor in self?.task = nil; self?.isLoading = false } }
            do {
                let fetched = try await UsageAPI.fetch()
                await MainActor.run { self?.apply(fetched) }
            } catch {
                await MainActor.run { self?.failed(with: error) }
            }
        }
    }

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
