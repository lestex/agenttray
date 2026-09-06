import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Entry point

// `AgentTray --dump [agent]` prints the raw usage payload, which is handy when
// an API grows a new window and the popover needs to learn about it. The agent
// is a provider id — "claude" (the default) or "codex".
if let flag = CommandLine.arguments.firstIndex(of: "--dump") {
    let name = CommandLine.arguments.dropFirst(flag + 1).first
    guard let provider = name.map(Providers.named) ?? Providers.all.first else {
        let known = Providers.all.map(\.id).joined(separator: ", ")
        FileHandle.standardError.write(Data("unknown agent \(name ?? ""); try one of: \(known)\n".utf8))
        exit(2)
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let (http, data) = try await provider.dump()
            if http.statusCode != 200 {
                var report = "HTTP \(http.statusCode)\n"
                for (key, value) in http.allHeaderFields {
                    report += "  \(key): \(value)\n"
                }
                FileHandle.standardError.write(Data(report.utf8))
            }
            let pretty = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
            FileHandle.standardOutput.write(pretty ?? data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// `delegate` stays a global because NSApplication holds its delegate weakly.
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
