import AppKit
import Foundation

enum PermissionReadiness: Equatable {
    case ready(String)
    case needsAction(String)
    case onDemand(String)
    case externalHost(String)

    var isBlocking: Bool {
        if case .needsAction = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .ready(let value), .needsAction(let value), .onDemand(let value), .externalHost(let value): value
        }
    }
}

struct UpgradePermissionReview: Identifiable, Equatable {
    let moduleID: String
    let permission: UpgradePermission
    let readiness: PermissionReadiness
    var id: String { permission.id }
}

@MainActor
final class PermissionOnboardingService {
    private static let attestationPrefix = "switchboard.permission.attested."

    func reviews(
        for selectedModuleIDs: Set<String>,
        plan: LegacyUpgradeReviewPlan,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> [UpgradePermissionReview] {
        let values = plan.modules
            .filter { selectedModuleIDs.contains($0.module.id) }
            .flatMap { review in
                review.contract.permissions.map { permission in
                    UpgradePermissionReview(
                        moduleID: review.module.id,
                        permission: permission,
                        readiness: readiness(permission, bundleURL: bundleURL)
                    )
                }
                .filter { permissionReview in
                    guard permissionReview.permission.mechanism == .appManagementAttestation else { return true }
                    return review.components.contains {
                        $0.isMigratable && $0.component.kind == .appBundle
                    }
                }
            }
        var seen = Set<String>()
        return values.filter { review in
            let key = review.permission.mechanism == .appManagementAttestation
                ? "app-management:\(review.permission.subject)"
                : review.permission.id
            return seen.insert(key).inserted
        }
    }

    func readiness(_ permission: UpgradePermission, bundleURL: URL = Bundle.main.bundleURL) -> PermissionReadiness {
        switch permission.mechanism {
        case .accessibilityHelper:
            guard let executable = permissionExecutable(permission, bundleURL: bundleURL) else {
                return .needsAction("The signed helper is missing")
            }
            return run(executable, ["--accessibility-status"]).status == 0
                ? .ready("Enabled for the exact helper")
                : .needsAction("Enable Accessibility for \(permission.subject)")
        case .fullDiskAccessHelper:
            guard let executable = permissionExecutable(permission, bundleURL: bundleURL) else {
                return .needsAction("The signed helper is missing")
            }
            let result = run(executable, ["--permission-status"])
            if result.status == 0 {
                return .ready("Protected Mail data is readable by the exact helper")
            }
            if result.status == 1 {
                return .needsAction("Enable Full Disk Access for \(permission.subject)")
            }
            return .onDemand("Mail data is not available yet; this is not treated as a permission denial")
        case .appManagementAttestation:
            return UserDefaults.standard.bool(forKey: Self.attestationPrefix + "app-management")
                ? .ready("Confirmed in System Settings")
                : .needsAction("Enable App Management for Switchboard, then confirm here")
        case .finderExtension:
            return .onDemand("Switchboard will register and verify the Finder extension during the upgrade")
        case .runtimePrompt:
            return .onDemand("macOS will ask the first time this selected feature talks to the target app")
        case .externalHost:
            return .externalHost("Permission belongs to the app that runs this command, not Switchboard")
        }
    }

    func request(_ permission: UpgradePermission, bundleURL: URL = Bundle.main.bundleURL) {
        switch permission.mechanism {
        case .accessibilityHelper:
            guard let executable = permissionExecutable(permission, bundleURL: bundleURL) else { return }
            _ = run(executable, ["--request-accessibility"])
        case .fullDiskAccessHelper, .appManagementAttestation:
            openSettings(permission)
        case .finderExtension, .runtimePrompt, .externalHost:
            break
        }
    }

    func revealSubject(_ permission: UpgradePermission, bundleURL: URL = Bundle.main.bundleURL) {
        guard let relative = permission.subjectRelativePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL.appending(path: relative)])
    }

    func markAppManagementConfirmed(_ permission: UpgradePermission) {
        guard permission.mechanism == .appManagementAttestation else { return }
        UserDefaults.standard.set(true, forKey: Self.attestationPrefix + "app-management")
    }

    private func openSettings(_ permission: UpgradePermission) {
        guard let value = permission.settingsURL, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func permissionExecutable(_ permission: UpgradePermission, bundleURL: URL) -> URL? {
        guard let relative = permission.subjectRelativePath else { return nil }
        let subject = bundleURL.appending(path: relative)
        if subject.pathExtension == "app",
           let bundle = Bundle(url: subject), let executable = bundle.executableURL {
            return executable
        }
        return subject
    }

    private func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return (-1, "") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
