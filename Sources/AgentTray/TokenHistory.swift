import Foundation

/// Tokens an agent processed over the last few days, read from the session
/// logs its CLI writes on this Mac. Nothing here touches the network: it is
/// what this machine did, not the account as a whole.
struct TokenHistory: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let start: Date
        let tokens: Int
    }

    struct Model: Equatable, Sendable {
        let name: String
        let tokens: Int
    }

    /// Oldest first, today last, one entry per day even when it is zero.
    var days: [Day] = []
    /// Busiest first; models with no tokens in the range are left out.
    var models: [Model] = []

    static let dayCount = 7
}

/// Adds up tokens by day and by model, dropping anything before the range.
struct TokenTally {
    let since: Date
    private var byDay: [Date: Int] = [:]
    private var byModel: [String: Int] = [:]
    private let calendar = Calendar.current

    init(days: Int = TokenHistory.dayCount, now: Date = Date()) {
        let today = calendar.startOfDay(for: now)
        since = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }

    mutating func add(_ tokens: Int, model: String, at date: Date) {
        guard tokens > 0, date >= since else { return }
        byDay[calendar.startOfDay(for: date), default: 0] += tokens
        byModel[model, default: 0] += tokens
    }

    func history(now: Date = Date()) -> TokenHistory {
        var days: [TokenHistory.Day] = []
        var day = since
        while day <= now {
            days.append(.init(start: day, tokens: byDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let models = byModel.map { TokenHistory.Model(name: $0.key, tokens: $0.value) }
            .sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
        return TokenHistory(days: days, models: models)
    }
}

// MARK: - Reading logs

enum SessionLogs {
    /// Every .jsonl under `root` written to since `date`. A session log is
    /// append-only, so one not modified in the range has nothing in it either.
    static func files(under root: URL, modifiedSince date: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return false }
            return modified >= date
        }
    }

    /// The lines of a log that mention one of `markers`, parsed. The substring
    /// check skips the JSON parse for the bulk of a log, which is message text.
    static func records(in file: URL, mentioning markers: String...) -> [[String: Any]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard markers.contains(where: { line.contains($0) }) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}

// MARK: - Claude

enum ClaudeHistory {
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Each assistant message carries its model and a usage block. A message
    /// can be written more than once — streamed in parts, or copied into a
    /// resumed session — so it is counted once per message and request id.
    static func load(now: Date = Date()) -> TokenHistory {
        var tally = TokenTally(now: now)
        var seen = Set<String>()
        for file in SessionLogs.files(under: projectsDirectory, modifiedSince: tally.since) {
            for record in SessionLogs.records(in: file, mentioning: "\"usage\"") {
                guard let message = record["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>",
                      let stamp = record["timestamp"] as? String,
                      let date = UsageAPI.parseDate(stamp) else { continue }
                if let id = message["id"] as? String {
                    let key = id + "|" + (record["requestId"] as? String ?? "")
                    guard seen.insert(key).inserted else { continue }
                }
                let tokens = ["input_tokens", "output_tokens",
                              "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + SessionLogs.int(usage[$1]) }
                tally.add(tokens, model: displayName(model), at: date)
            }
        }
        return tally.history(now: now)
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5".
    static func displayName(_ id: String) -> String {
        let bare = id.split(separator: "[").first.map(String.init) ?? id
        let parts = bare.split(separator: "-").map(String.init).filter { $0 != "claude" }
        let words = parts.filter { $0.first?.isLetter == true }
        // A trailing 8-digit date is a snapshot, not part of the version.
        let version = parts.filter { $0.allSatisfy(\.isNumber) && $0.count < 8 }
        guard !words.isEmpty else { return id }
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return version.isEmpty ? name : name + " " + version.joined(separator: ".")
    }
}

// MARK: - Codex

enum CodexHistory {
    static var sessionsDirectory: URL {
        CodexCredentials.authFile.deletingLastPathComponent().appendingPathComponent("sessions")
    }

    /// A session log reports a running total in each `token_count` event, so a
    /// turn's tokens are the step from the previous total, credited to the
    /// model the latest `turn_context` named. A repeated event steps by zero.
    static func load(now: Date = Date()) -> TokenHistory {
        var tally = TokenTally(now: now)
        for file in SessionLogs.files(under: sessionsDirectory, modifiedSince: tally.since) {
            var model = "Codex"
            var total = 0
            for record in SessionLogs.records(in: file, mentioning: "\"turn_context\"", "\"token_count\"") {
                let payload = record["payload"] as? [String: Any] ?? [:]
                if record["type"] as? String == "turn_context", let named = payload["model"] as? String {
                    model = displayName(named)
                }
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any],
                      let stamp = record["timestamp"] as? String,
                      let date = UsageAPI.parseDate(stamp) else { continue }
                let running = SessionLogs.int(usage["total_tokens"])
                // A total that goes down means the counter started again.
                let step = running >= total ? running - total : running
                total = running
                tally.add(step, model: model, at: date)
            }
        }
        return tally.history(now: now)
    }

    /// "gpt-5.6-luna" → "GPT-5.6 Luna".
    static func displayName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        guard parts.first?.lowercased() == "gpt", parts.count >= 2 else { return id }
        let head = "GPT-" + parts[1]
        parts.removeFirst(2)
        return ([head] + parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }
}
