import Foundation
import Security

// MARK: - Model

/// One rate-limit window reported by the API.
struct Limit: Identifiable, Equatable, Codable {
    let key: String          // raw API key, e.g. "five_hour"
    let title: String        // "5-hour window"
    let short: String?       // "5H" — nil hides it from the menu bar
    let utilization: Double  // 0...100
    let resetsAt: Date?
    let order: Int

    var id: String { key }
}

/// Pay-as-you-go credits that kick in past the plan limits.
struct ExtraUsage: Equatable, Codable {
    let utilization: Double
    let used: String
    let limit: String
}

struct Snapshot: Equatable, Codable {
    var limits: [Limit] = []
    var extra: ExtraUsage?
}

enum UsageError: LocalizedError {
    case noCredentials
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badPayload

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude credentials found in the Keychain. Log in with `claude` first."
        case .unauthorized:
            return "Token rejected. Run `claude` in a terminal to refresh the login."
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Rate limited by the API (HTTP 429)." }
            return "Rate limited by the API (HTTP 429), for another \(Int(retryAfter)) s."
        case .http(let code):
            return "API returned HTTP \(code)."
        case .badPayload:
            return "Could not read the usage payload."
        }
    }
}

// MARK: - Credentials

enum Credentials {
    /// Claude Code stores its OAuth blob as a generic password under this service.
    static let keychainService = "Claude Code-credentials"

    static func accessToken() -> String? {
        if let data = keychainBlob(), let token = findString(key: "accessToken", in: data) {
            return token
        }
        // Fallback for setups that keep credentials on disk instead.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) {
            return findString(key: "accessToken", in: data)
        }
        return nil
    }

    private static func keychainBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// The blob nests the token under a provider key, so walk the JSON for it.
    private static func findString(key: String, in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func walk(_ any: Any) -> String? {
            if let dict = any as? [String: Any] {
                if let hit = dict[key] as? String, !hit.isEmpty { return hit }
                for value in dict.values { if let hit = walk(value) { return hit } }
            } else if let array = any as? [Any] {
                for value in array { if let hit = walk(value) { return hit } }
            }
            return nil
        }
        return walk(root)
    }
}

// MARK: - Fetching

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The only network call the app makes. Ephemeral: a credentialed request
    /// has no business leaving cookies or cached responses on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The bare request, so `--dump` can report the status and headers when the
    /// call fails.
    static func perform() async throws -> (HTTPURLResponse, Data) {
        guard let token = Credentials.accessToken() else { throw UsageError.noCredentials }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentTray/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badPayload }
        return (http, data)
    }

    static func fetchRaw() async throws -> Data {
        let (http, data) = try await perform()
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw UsageError.unauthorized
        case 429:
            throw UsageError.rateLimited(retryAfter: retryAfter(from: http))
        default: throw UsageError.http(http.statusCode)
        }
    }

    static func fetch() async throws -> Snapshot {
        let snapshot = parse(try await fetchRaw())
        guard !snapshot.limits.isEmpty else { throw UsageError.badPayload }
        return snapshot
    }

    /// Retry-After is either delta-seconds or an HTTP date. A zero or a past
    /// date tells us nothing, so it falls back to our own backoff.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(header) { return seconds > 0 ? seconds : nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        let delay = date.timeIntervalSinceNow
        return delay > 0 ? delay : nil
    }

    // MARK: Parsing

    /// Display metadata for the windows we know about. Anything else still shows
    /// up in the popover with a humanised title, so a new window won't be dropped.
    private static let known: [String: (title: String, short: String?, order: Int)] = [
        "five_hour": ("5-hour window", "5H", 0),
        "seven_day": ("Weekly", "WEEK", 1),
        // The weekly top-model window ships under a rotating codename.
        "nimbus_quill": ("Weekly Fable", "FABLE", 2),
        "seven_day_fable": ("Weekly Fable", "FABLE", 2),
        "seven_day_opus": ("Weekly Opus", "OPUS", 2),
        "seven_day_sonnet": ("Weekly Sonnet", nil, 3),
        "seven_day_oauth_apps": ("Weekly (apps)", nil, 4),
    ]

    /// Dollar-denominated blocks that are reported alongside the windows but
    /// are not rate limits; they get their own footer line instead.
    private static let notALimit: Set<String> = ["extra_usage", "spend"]

    static func parse(_ data: Data) -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Snapshot() }
        var limits = collect(from: root)
        if limits.isEmpty {
            // Tolerate a wrapped payload such as {"usage": {...}}.
            for value in root.values {
                if let nested = value as? [String: Any] {
                    limits = collect(from: nested)
                    if !limits.isEmpty { break }
                }
            }
        }
        return Snapshot(limits: limits.sorted { ($0.order, $0.title) < ($1.order, $1.title) },
                        extra: extraUsage(in: root))
    }

    private static func extraUsage(in root: [String: Any]) -> ExtraUsage? {
        guard let block = root["extra_usage"] as? [String: Any],
              (block["is_enabled"] as? Bool) == true,
              let used = block["used_credits"] as? NSNumber,
              let cap = block["monthly_limit"] as? NSNumber else { return nil }
        let exponent = (block["decimal_places"] as? NSNumber)?.intValue ?? 2
        let currency = block["currency"] as? String ?? "USD"
        let utilization = (block["utilization"] as? NSNumber)?.doubleValue
            ?? (cap.doubleValue > 0 ? used.doubleValue / cap.doubleValue * 100 : 0)
        return ExtraUsage(utilization: min(max(utilization, 0), 100),
                          used: money(used.doubleValue, exponent: exponent, currency: currency),
                          limit: money(cap.doubleValue, exponent: exponent, currency: currency))
    }

    /// Amounts arrive as minor units (946 cents) plus the exponent to shift by.
    private static func money(_ minor: Double, exponent: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let value = minor / pow(10, Double(exponent))
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func collect(from dict: [String: Any]) -> [Limit] {
        dict.compactMap { key, value in
            guard !notALimit.contains(key),
                  let window = value as? [String: Any],
                  let used = percent(in: window) else { return nil }
            let meta = known[key] ?? (humanise(key), nil, 3)
            return Limit(key: key,
                         title: meta.title,
                         short: meta.short,
                         utilization: used,
                         resetsAt: resetDate(in: window),
                         order: meta.order)
        }
    }

    private static func percent(in window: [String: Any]) -> Double? {
        for field in ["utilization", "used_percentage"] {
            if let n = window[field] as? NSNumber {
                return min(max(n.doubleValue, 0), 100)
            }
        }
        return nil
    }

    private static func resetDate(in window: [String: Any]) -> Date? {
        for field in ["resets_at", "reset_at", "resetsAt", "resets"] {
            guard let value = window[field] else { continue }
            if let text = value as? String, let date = parseDate(text) { return date }
            if let n = value as? NSNumber {
                // Epoch seconds or milliseconds.
                let raw = n.doubleValue
                return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
            }
        }
        return nil
    }

    /// Accepts "2026-09-02T04:10:00.464945+00:00" as well as plain RFC 3339:
    /// ISO8601DateFormatter only tolerates up to three fractional digits, so
    /// the fraction is dropped before parsing.
    static func parseDate(_ text: String) -> Date? {
        if let date = isoWithFraction.date(from: text) ?? iso.date(from: text) { return date }
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let tail = text[dot...].drop { $0.isNumber || $0 == "." }
        return iso.date(from: String(text[..<dot]) + tail)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func humanise(_ key: String) -> String {
        let words = key.split(separator: "_").map(String.init)
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

// MARK: - Formatting

enum Format {
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let total = Int(date.timeIntervalSince(now).rounded())
        if total <= 0 { return "Resetting now" }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "Resets in \(days) d \(hours) h \(minutes) min" }
        if hours > 0 { return "Resets in \(hours) h \(minutes) min \(seconds) s" }
        if minutes > 0 { return "Resets in \(minutes) min \(seconds) s" }
        return "Resets in \(seconds) s"
    }

    static func percent(_ value: Double, spaced: Bool = true) -> String {
        let gap = spaced ? " " : ""
        let rounded = (value * 10).rounded() / 10
        if rounded > 0, rounded < 10, rounded != rounded.rounded() {
            return String(format: "%.1f%@%%", rounded, gap)
        }
        return String(format: "%.0f%@%%", rounded, gap)
    }
}
