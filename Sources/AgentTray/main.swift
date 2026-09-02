import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Entry point

// `AgentTray --dump` prints the raw usage payload, which is handy when the
// API grows a new window and the popover needs to learn about it.
if CommandLine.arguments.contains("--dump") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let (http, data) = try await UsageAPI.perform()
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
