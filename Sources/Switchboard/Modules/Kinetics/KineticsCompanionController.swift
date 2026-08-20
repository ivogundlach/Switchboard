import Foundation

/// Describes the nested Kinetics companion without starting it.
///
/// The Switchboard agent is the only process owner. This controller is a
/// read-only readiness check used by the module UI and tests; it deliberately
/// has no Process, launch-agent, or login-item behavior.
final class KineticsCompanionController {
    static let moduleID = "desktop.kinetics"
    static let bundleIdentifier = "com.ivogundlach.Kinetics"
    static let companionRelativePath = "Contents/Resources/Companions/Kinetics.app"
    static let executableRelativePath = "Contents/MacOS/Kinetics"

    private(set) var isReady = false
    private(set) var lastFailure: String?

    func refresh(bundleURL: URL) {
        do {
            _ = try Self.validate(bundleURL: bundleURL)
            isReady = true
            lastFailure = nil
        } catch {
            isReady = false
            lastFailure = error.localizedDescription
        }
    }

    func stop() {
        isReady = false
        lastFailure = nil
    }

    @discardableResult
    static func validate(bundleURL: URL, fileManager: FileManager = .default) throws -> URL {
        let outerValues = try bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard outerValues.isDirectory == true, outerValues.isSymbolicLink != true else {
            throw KineticsCompanionError.invalidOuterBundle
        }

        let companionURL = bundleURL.appending(path: companionRelativePath, directoryHint: .isDirectory)
        let companionValues = try companionURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard companionValues.isDirectory == true, companionValues.isSymbolicLink != true else {
            throw KineticsCompanionError.missingCompanion
        }

        let infoURL = companionURL.appending(path: "Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)
                as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == "Kinetics",
              info["LSUIElement"] as? Bool == true,
              info["LSMinimumSystemVersion"] as? String == "26.0" else {
            throw KineticsCompanionError.invalidIdentity
        }

        let executableURL = companionURL.appending(path: executableRelativePath)
        let executableValues = try executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
        )
        guard executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true,
              executableValues.isExecutable == true else {
            throw KineticsCompanionError.missingExecutable
        }

        guard let enumerator = fileManager.enumerator(
            at: companionURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw KineticsCompanionError.missingCompanion }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw KineticsCompanionError.missingCompanion
            }
            guard !url.pathComponents.contains(where: {
                let component = $0.lowercased()
                return component.contains("loginlauncher") || component.contains("kinetics login launcher")
            }) else {
                throw KineticsCompanionError.loginLauncherBundled
            }
        }
        return executableURL
    }
}

enum KineticsCompanionError: LocalizedError, Equatable {
    case invalidOuterBundle
    case missingCompanion
    case invalidIdentity
    case missingExecutable
    case loginLauncherBundled

    var errorDescription: String? {
        switch self {
        case .invalidOuterBundle: "The Switchboard bundle is not a regular directory."
        case .missingCompanion: "The nested Kinetics companion is missing or unsafe."
        case .invalidIdentity: "The nested Kinetics companion identity or background settings are invalid."
        case .missingExecutable: "The nested Kinetics executable is missing or unsafe."
        case .loginLauncherBundled: "The legacy Kinetics LoginLauncher must not be nested inside the companion."
        }
    }
}
