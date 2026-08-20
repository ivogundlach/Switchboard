import Foundation

enum CanonicalInstallGate {
    static let requiredBundleURL = URL(fileURLWithPath: "/Applications/Switchboard.app", isDirectory: true)

    static func isCanonical(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.resolvingSymlinksInPath().standardizedFileURL == requiredBundleURL
    }
}
