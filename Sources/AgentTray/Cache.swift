import Foundation

/// Last known usage, kept on disk so a relaunch shows numbers immediately
/// instead of an empty panel — and so a restart during a rate-limit backoff
/// still has something to display.
enum Cache {
    private struct Payload: Codable {
        let fetchedAt: Date
        let snapshot: Snapshot
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

    static func load() -> (snapshot: Snapshot, fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return (payload.snapshot, payload.fetchedAt)
    }

    static func save(_ snapshot: Snapshot, fetchedAt: Date) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Payload(fetchedAt: fetchedAt, snapshot: snapshot))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AgentTray: could not cache usage: \(error.localizedDescription)")
        }
    }
}
