import Foundation

// MARK: - Credentials

/// Codex keeps its ChatGPT login in a file rather than the Keychain, and
/// refreshes it whenever the CLI runs. We only ever read it: the refresh token
/// rotates, so renewing it here would log the CLI out.
enum CodexCredentials {
    struct Token {
        let accessToken: String
        let accountID: String?
    }

    /// `CODEX_HOME` moves the whole directory, the same way the CLI reads it.
    static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    static func token() -> Token? {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        return Token(accessToken: access, accountID: tokens["account_id"] as? String)
    }
}

// MARK: - Fetching

enum CodexAPI {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static let missingLogin = "No Codex credentials found in ~/.codex/auth.json. Log in with `codex` first."
    static let staleLogin = "Token rejected. Run `codex` in a terminal to refresh the login."

    /// The bare request, so `--dump` can report the status and headers when the
    /// call fails.
    static func perform() async throws -> (HTTPURLResponse, Data) {
        guard let token = CodexCredentials.token() else { throw UsageError.noCredentials(missingLogin) }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = token.accountID {
            request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("AgentTray/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await HTTP.send(request)
    }

    static func fetch() async throws -> Snapshot {
        let (http, data) = try await perform()
        let snapshot = parse(try HTTP.body(http, data, staleLogin: staleLogin))
        guard !snapshot.limits.isEmpty else { throw UsageError.badPayload }
        return snapshot
    }

    // MARK: Parsing

    /// Two fixed slots rather than the named windows Claude reports, so the
    /// titles come from how long each window is — a plan whose windows differ
    /// still labels itself correctly.
    static func parse(_ data: Data) -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["rate_limit"] as? [String: Any] else { return Snapshot() }
        let limits = ["primary_window", "secondary_window"].enumerated().compactMap { order, key in
            (block[key] as? [String: Any]).flatMap { limit(key, $0, order: order) }
        }
        return Snapshot(limits: limits)
    }

    private static func limit(_ key: String, _ window: [String: Any], order: Int) -> Limit? {
        guard let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let named = name(forWindowOf: (window["limit_window_seconds"] as? NSNumber)?.doubleValue)
        return Limit(key: key,
                     title: named.title,
                     short: named.short,
                     utilization: min(max(used, 0), 100),
                     resetsAt: resetDate(in: window),
                     order: order)
    }

    private static func name(forWindowOf seconds: Double?) -> (title: String, short: String?) {
        guard let seconds, seconds >= 3600 else { return ("Window", nil) }
        let hours = Int((seconds / 3600).rounded())
        if hours % 168 == 0 {
            let weeks = hours / 168
            return weeks == 1 ? ("Weekly", "WEEK") : ("\(weeks)-week window", "\(weeks)W")
        }
        if hours % 24 == 0 {
            let days = hours / 24
            return ("\(days)-day window", "\(days)D")
        }
        return ("\(hours)-hour window", "\(hours)H")
    }

    /// `reset_at` is epoch seconds; the countdown falls back to the offset when
    /// the absolute time is missing.
    private static func resetDate(in window: [String: Any]) -> Date? {
        if let at = (window["reset_at"] as? NSNumber)?.doubleValue, at > 0 {
            return Date(timeIntervalSince1970: at > 1e11 ? at / 1000 : at)
        }
        if let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue {
            return Date().addingTimeInterval(after)
        }
        return nil
    }
}
