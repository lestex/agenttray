import Foundation

enum AppInfo {
    /// The bundle's version: the release tag, or for a local build the commit it
    /// was made from. "dev" when the binary runs outside a bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
