import AppKit
import Foundation

enum LegacyUpgradeDetection: String, Codable, Equatable {
    case running
    case enabled
    case installed
    case retained
    case alreadyRetired
    case notFound
    case unresolved

    var label: String {
        switch self {
        case .running: "Running"
        case .enabled: "Enabled"
        case .installed: "Installed"
        case .retained: "Retained — replacement is not verified"
        case .alreadyRetired: "Already migrated"
        case .notFound: "Not found"
        case .unresolved: "Found outside the safe migration location"
        }
    }
}

struct LegacyUpgradeComponentEvidence: Identifiable, Equatable {
    let component: UpgradeLegacyComponent
    let detection: LegacyUpgradeDetection
    let detail: String

    var id: String { component.id }
    var isDetected: Bool { detection != .notFound }
    var isMigratable: Bool {
        isDetected && detection != .unresolved && detection != .alreadyRetired && component.disposition == .migrate
    }
}

struct LegacyUpgradeModuleReview: Identifiable, Equatable {
    let module: ModuleDefinition
    let contract: UpgradeMigrationModule
    let components: [LegacyUpgradeComponentEvidence]
    let legacyEnabled: Bool
    let wasPreviouslyImported: Bool
    let alreadyEnabledInSwitchboard: Bool
    let legacySettingsSummary: [String]

    var id: String { module.id }
    var hasLegacyEvidence: Bool { components.contains(where: \.isDetected) }
    var hasMigratableEvidence: Bool { components.contains(where: \.isMigratable) }
    var hasRetainedEvidence: Bool {
        components.contains { $0.isDetected && $0.component.disposition == .retain }
    }
    var recommendedSelected: Bool {
        hasMigratableEvidence
            || (wasPreviouslyImported && !alreadyEnabledInSwitchboard)
            || (contract.settingsPolicy == .sharedCanonical && !alreadyEnabledInSwitchboard)
    }
}

struct LegacyUpgradeReviewPlan: Equatable {
    let modules: [LegacyUpgradeModuleReview]
    let createdAt: Date

    var shouldPresentOnUserLaunch: Bool {
        modules.contains { $0.hasMigratableEvidence || $0.recommendedSelected }
    }
}

struct LegacyUpgradeScanSnapshot {
    let existingPaths: Set<String>
    let runningAppPaths: Set<String>
    let loadedLaunchAgentLabels: Set<String>
    let cronText: String
    let defaultsDomains: [String: [String: AnyHashable]]
    let shortcutNames: Set<String>
    let importedModuleIDs: Set<String>
    var uncertainAppPaths: [String: [String]] = [:]
}

enum LegacyUpgradeScanner {
    static func scan(
        manifest: ModuleManifest,
        contract: UpgradeMigrationContract,
        enabledSwitchboardIDs: Set<String>,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LegacyUpgradeReviewPlan {
        let snapshot = liveSnapshot(manifest: manifest, contract: contract, homeDirectory: homeDirectory)
        return plan(
            manifest: manifest,
            contract: contract,
            enabledSwitchboardIDs: enabledSwitchboardIDs,
            snapshot: snapshot,
            homeDirectory: homeDirectory
        )
    }

    static func plan(
        manifest: ModuleManifest,
        contract: UpgradeMigrationContract,
        enabledSwitchboardIDs: Set<String>,
        snapshot: LegacyUpgradeScanSnapshot,
        homeDirectory: URL
    ) -> LegacyUpgradeReviewPlan {
        let contractByModule = Dictionary(uniqueKeysWithValues: contract.modules.map { ($0.moduleID, $0) })
        let reviews = manifest.modules.compactMap { module -> LegacyUpgradeModuleReview? in
            guard let moduleContract = contractByModule[module.id] else { return nil }
            let components = moduleContract.legacyComponents.map {
                evidence(
                    for: $0,
                    module: module,
                    manifest: manifest,
                    snapshot: snapshot,
                    homeDirectory: homeDirectory
                )
            }
            let kineticsDomain = snapshot.defaultsDomains["com.ivogundlach.Kinetics"]
            let kineticsEnabled = kineticsDomain?["desktopSwitching.enabled"] as? Bool ?? false
            let legacyEnabled = module.id == "desktop.kinetics"
                ? kineticsEnabled
                : components.contains { $0.detection == .running || $0.detection == .enabled }
            let settings = module.configKeys.filter { key in
                moduleContract.settingsPolicy == .sharedCanonical || !key.isEmpty
            }
            return LegacyUpgradeModuleReview(
                module: module,
                contract: moduleContract,
                components: components,
                legacyEnabled: legacyEnabled,
                wasPreviouslyImported: snapshot.importedModuleIDs.contains(module.id),
                alreadyEnabledInSwitchboard: enabledSwitchboardIDs.contains(module.id),
                legacySettingsSummary: settings
            )
        }
        return LegacyUpgradeReviewPlan(modules: reviews, createdAt: Date())
    }

    private static func liveSnapshot(
        manifest: ModuleManifest,
        contract: UpgradeMigrationContract,
        homeDirectory: URL
    ) -> LegacyUpgradeScanSnapshot {
        var paths = Set<String>()
        var running = Set<String>()
        var loaded = Set<String>()
        var uncertainApps: [String: [String]] = [:]
        let fileManager = FileManager.default
        for module in contract.modules {
            for component in module.legacyComponents {
                if let path = component.canonicalPath, fileManager.fileExists(atPath: path) {
                    paths.insert(path)
                    if let bundleID = component.bundleID {
                        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        where app.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path {
                            running.insert(path)
                        }
                    }
                }
                if component.kind == .appBundle, let bundleID = component.bundleID {
                    let result = run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleID)'c"])
                    if result.status == 0 {
                        let canonical = component.canonicalPath ?? ""
                        let candidates = result.output.split(whereSeparator: \.isNewline).map(String.init)
                            .filter { $0 != canonical && $0.hasSuffix(".app") }
                        if !candidates.isEmpty { uncertainApps[component.id] = candidates }
                    }
                }
                if let label = component.label, component.kind == .launchAgent {
                    let plist = homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist")
                    if fileManager.fileExists(atPath: plist.path) { paths.insert(plist.path) }
                    if launchAgentIsLoaded(label) { loaded.insert(label) }
                }
            }
        }
        for family in manifest.ownedCommandFamilies where family.owner.hasPrefix("switchboard:") {
            for name in family.items {
                let path = homeDirectory.appending(path: ".local/bin/\(name)").path
                if fileManager.fileExists(atPath: path) { paths.insert(path) }
            }
        }
        for name in manifest.memoryToolCandidates {
            let path = homeDirectory.appending(path: ".local/bin/\(name)").path
            if fileManager.fileExists(atPath: path) { paths.insert(path) }
        }
        for service in manifest.macOSServices where service.owner.hasPrefix("switchboard:") {
            let path = homeDirectory.appending(path: "Library/Services/\(service.name)").path
            if fileManager.fileExists(atPath: path) { paths.insert(path) }
        }
        let domains = ["com.ivogundlach.Kinetics"].reduce(into: [String: [String: AnyHashable]]()) { result, domain in
            let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            result[domain] = values.compactMapValues { $0 as? AnyHashable }
        }
        return LegacyUpgradeScanSnapshot(
            existingPaths: paths,
            runningAppPaths: running,
            loadedLaunchAgentLabels: loaded,
            cronText: currentCrontab(),
            defaultsDomains: domains,
            shortcutNames: currentShortcutNames(),
            importedModuleIDs: Set(manifest.modules.compactMap {
                UserDefaults.standard.bool(forKey: "switchboard.upgrade.imported.\($0.id).v1") ? $0.id : nil
            }),
            uncertainAppPaths: uncertainApps
        )
    }

    private static func evidence(
        for component: UpgradeLegacyComponent,
        module: ModuleDefinition,
        manifest: ModuleManifest,
        snapshot: LegacyUpgradeScanSnapshot,
        homeDirectory: URL
    ) -> LegacyUpgradeComponentEvidence {
        if snapshot.importedModuleIDs.contains(module.id), component.disposition == .migrate,
           component.kind == .command || component.kind == .service || component.kind == .preference || component.kind == .shortcut {
            return .init(component: component, detection: .alreadyRetired, detail: "Already imported into Switchboard.")
        }
        if component.disposition == .alreadyRetired {
            let exists = component.canonicalPath.map(snapshot.existingPaths.contains) ?? false
            return .init(
                component: component,
                detection: exists ? .installed : .alreadyRetired,
                detail: exists ? "The old app is still installed." : "The old app has already been retired safely."
            )
        }

        let detected: Bool
        let enabled: Bool
        let detail: String
        switch component.kind {
        case .appBundle:
            let path = component.canonicalPath ?? ""
            detected = snapshot.existingPaths.contains(path)
            enabled = snapshot.runningAppPaths.contains(path)
            detail = detected ? path : "No exact legacy app was found."
            if !detected, let candidates = snapshot.uncertainAppPaths[component.id], !candidates.isEmpty {
                return .init(
                    component: component,
                    detection: .unresolved,
                    detail: "Possible related app: \(candidates.joined(separator: ", ")). Switchboard will not alter it."
                )
            }
        case .launchAgent:
            let label = component.label ?? ""
            let path = homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist").path
            detected = snapshot.existingPaths.contains(path) || snapshot.loadedLaunchAgentLabels.contains(label)
            enabled = snapshot.loadedLaunchAgentLabels.contains(label)
            detail = detected ? label : "No exact legacy background job was found."
        case .cron:
            let line = LegacySchedulerMigration.backupAuditCronLine(homeDirectory: homeDirectory)
            detected = LegacySchedulerMigration.containsExactCronLine(line, in: Data(snapshot.cronText.utf8))
            enabled = detected
            detail = detected ? "Exact daily backup audit entry" : "The exact legacy cron entry was not found."
        case .command:
            let names = commandNames(for: module.id, manifest: manifest)
            let found = names.filter { snapshot.existingPaths.contains(homeDirectory.appending(path: ".local/bin/\($0)").path) }
            detected = !found.isEmpty
            enabled = detected
            detail = detected ? "Existing commands: \(found.sorted().joined(separator: ", "))" : "No existing command from this module was found."
        case .service:
            let names = manifest.macOSServices.filter { $0.owner == "switchboard:\(module.id)" }.map(\.name)
            let found = names.filter { snapshot.existingPaths.contains(homeDirectory.appending(path: "Library/Services/\($0)").path) }
            detected = !found.isEmpty
            enabled = detected
            detail = detected ? "Existing Services: \(found.sorted().joined(separator: ", "))" : "No exact legacy Service was found."
        case .preference:
            let domain = component.defaultsDomain ?? ""
            let key = component.defaultsKey ?? ""
            detected = snapshot.defaultsDomains[domain]?[key] != nil
            enabled = detected
            detail = detected ? "Existing setting \(domain):\(key)" : "No matching legacy setting was found."
        case .shortcut:
            detected = snapshot.shortcutNames.contains(component.displayName)
            enabled = detected
            detail = detected ? "The Mac-specific brightness shortcut will be replaced by native Switchboard behavior." : "The exact Mac shortcut was not found."
        }

        if component.disposition == .retain, detected {
            return .init(component: component, detection: .retained, detail: detail)
        }
        let detection: LegacyUpgradeDetection = !detected ? .notFound : (enabled ? (component.kind == .appBundle ? .running : .enabled) : .installed)
        return .init(component: component, detection: detection, detail: detail)
    }

    private static func commandNames(for moduleID: String, manifest: ModuleManifest) -> [String] {
        var values = manifest.ownedCommandFamilies
            .filter { $0.owner == "switchboard:\(moduleID)" }
            .flatMap(\.items)
        if moduleID == "systems.memory" { values.append(contentsOf: manifest.memoryToolCandidates) }
        return values
    }

    private static func launchAgentIsLoaded(_ label: String) -> Bool {
        let result = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        return result.status == 0
    }

    private static func currentCrontab() -> String {
        let result = run("/usr/bin/crontab", ["-l"])
        return result.status == 0 ? result.output : ""
    }

    private static func currentShortcutNames() -> Set<String> {
        let result = run("/usr/bin/shortcuts", ["list"])
        guard result.status == 0 else { return [] }
        return Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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
