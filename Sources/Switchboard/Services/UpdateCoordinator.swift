import Foundation
import Observation

enum SwitchboardUpdateStatus: Equatable {
    case idle
    case checking
    case current
    case available(String)
    case downloading(String)
    case handingOff(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle: "Updates are checked only when you ask."
        case .checking: "Checking the signed GitHub release…"
        case .current: "This is the newest published version."
        case .available(let version): "Version \(version) is available."
        case .downloading(let version): "Downloading and verifying version \(version)…"
        case .handingOff(let version): "Installing version \(version) in the background. Switchboard will close."
        case .failed(let detail): detail
        }
    }
}

@MainActor
@Observable
final class UpdateCoordinator {
    private(set) var status: SwitchboardUpdateStatus = .idle
    private(set) var availableUpdate: SwitchboardUpdate?
    private let service: GitHubUpdateService

    init(service: GitHubUpdateService = GitHubUpdateService()) {
        self.service = service
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking
        do {
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            availableUpdate = try await service.checkForUpdate(currentVersion: current)
            status = availableUpdate.map { .available($0.manifest.version) } ?? .current
        } catch GitHubUpdateServiceError.invalidHTTPStatus(404) {
            availableUpdate = nil
            status = .current
        } catch {
            availableUpdate = nil
            status = .failed("Update check failed: \(error.localizedDescription)")
        }
    }

    /// Returns true only after the fixed embedded updater helper has started.
    func installAvailableUpdate() async -> Bool {
        guard let update = availableUpdate else {
            status = .failed("Check for an update before installing.")
            return false
        }
        guard CanonicalInstallGate.isCanonical() else {
            status = .failed("Updates require Switchboard to be installed in Applications.")
            return false
        }
        let trustedTeam = Bundle.main.object(
            forInfoDictionaryKey: UpdateInstallerConstants.trustAnchorInfoPlistKey
        ) as? String
        guard trustedTeam == update.manifest.teamIdentifier else {
            status = .failed("The update signing team does not match this installed copy.")
            return false
        }

        status = .downloading(update.manifest.version)
        do {
            let fileManager = FileManager.default
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Switchboard", directoryHint: .isDirectory)
            let updates = support.appending(path: "Updates", directoryHint: .isDirectory)
            try ensureOwnerOnlyDirectory(support)
            try ensureOwnerOnlyDirectory(updates)
            let image = updates.appending(path: "\(UUID().uuidString).dmg")
            _ = try await service.downloadAndVerify(update, to: image)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
            try launchHelper(imageURL: image, version: update.manifest.version, supportURL: support)
            status = .handingOff(update.manifest.version)
            return true
        } catch {
            status = .failed("Update installation could not start: \(error.localizedDescription)")
            return false
        }
    }

    private func ensureOwnerOnlyDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func launchHelper(imageURL: URL, version: String, supportURL: URL) throws {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let helper = resources.appending(path: "Helpers/switchboard-updater")
        let values = try helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExecutable == true else {
            throw CocoaError(.fileNoSuchFile)
        }

        let logURL = supportURL.appending(path: "update.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "--image", imageURL.path,
            "--version", version,
            "--parent-pid", String(getpid()),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }
    }
}
