import Foundation

/// Last known usage per provider, kept on disk so a relaunch shows numbers
/// immediately — and so a restart during a rate-limit backoff still has
/// something to display.
enum Cache {
    struct Entry: Codable {
        let fetchedAt: Date
        let snapshot: Snapshot
    }

    private struct File: Codable {
        var providers: [String: Entry]
    }

    private static let fileURL: URL = {
        // AGENTTRAY_CACHE_DIR keeps test and preview runs out of the real cache.
        if let override = ProcessInfo.processInfo.environment["AGENTTRAY_CACHE_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("usage.json")
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.lestex.agenttray/usage.json")
    }()

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            return file.providers
        }
        // A cache written before the app knew about more than one agent.
        if let single = try? JSONDecoder().decode(Entry.self, from: data) {
            return ["claude": single]
        }
        return [:]
    }

    static func save(_ providers: [String: Entry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(File(providers: providers))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AgentTray: could not cache usage: \(error.localizedDescription)")
        }
    }
}
