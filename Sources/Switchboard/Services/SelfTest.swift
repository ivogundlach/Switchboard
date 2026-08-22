import Foundation

enum SelfTest {
    static func run() throws {
        guard let manifestURL = Bundle.main.url(forResource: "ModuleManifest", withExtension: "json"),
              let contractURL = Bundle.main.url(forResource: "WarmCornersMigrationContract", withExtension: "json"),
              let baselineURL = Bundle.main.url(forResource: "InventoryBaseline", withExtension: "json"),
              let runtimeURL = Bundle.main.url(forResource: "RuntimeManifest", withExtension: "json"),
              let upgradeContractURL = Bundle.main.url(forResource: "UpgradeMigrationContract", withExtension: "json") else {
            throw SelfTestError.missingResource
        }

        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: manifestURL))
        try ManifestValidator.validate(manifest)
        _ = try UpgradeMigrationContract.load(
            from: upgradeContractURL,
            moduleIDs: Set(manifest.modules.map(\.id))
        )
        guard let smartWake = manifest.modules.first(where: { $0.id == "desktop.smart-wake" }),
              smartWake.availability == .ready,
              smartWake.legacyLabels == ["com.user.smartwake", "com.user.smartwake.discord"] else {
            throw SelfTestError.smartWakeReadiness
        }
        let smartWakeComponents = manifest.scheduledComponents.filter { $0.owner == "switchboard:desktop.smart-wake" }
        guard smartWakeComponents.contains(where: { $0.label == "com.user.smartwake.sleep-guard" && $0.cadence.contains("retained outside generic migration") }),
              smartWakeComponents.contains(where: { $0.label == "com.user.smartwake.imessage" && $0.cadence.contains("source unresolved") }) else {
            throw SelfTestError.smartWakeReadiness
        }
        let baseline = try JSONDecoder().decode(InventoryBaseline.self, from: Data(contentsOf: baselineURL))
        try baseline.validate(manifest)
        let runtime = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: runtimeURL))
        try RuntimeManifestValidator.validate(runtime, moduleIDs: Set(manifest.modules.map(\.id)))
        try validateKineticsBoundary(manifest: manifest, runtime: runtime, bundleURL: Bundle.main.bundleURL)
        let scheduledOwners = Dictionary(uniqueKeysWithValues: manifest.scheduledComponents.map { ($0.label, $0.owner) })
        guard runtime.jobs.allSatisfy({ scheduledOwners[$0.label] == "switchboard:\($0.moduleID)" }) else {
            throw SelfTestError.runtimeOwnershipMismatch
        }
        let resourcesURL = Bundle.main.resourceURL!
        for job in runtime.jobs {
            let executable = resourcesURL.appending(path: job.executable)
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isExecutable == true else {
                throw SelfTestError.missingRuntimeExecutable(job.label)
            }
        }
        var bundledCommands: [String: [String]] = [:]
        for family in manifest.ownedCommandFamilies where family.owner.hasPrefix("switchboard:") {
            let moduleID = String(family.owner.dropFirst("switchboard:".count))
            bundledCommands[moduleID, default: []].append(contentsOf: family.items)
        }
        bundledCommands["systems.memory", default: []].append(contentsOf: manifest.memoryToolCandidates)
        for (moduleID, commands) in bundledCommands {
            for command in commands {
                let executable = resourcesURL
                    .appending(path: "Modules/\(moduleID)/bin/\(command)")
                let values = try executable.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      values.isExecutable == true else {
                    throw SelfTestError.missingBundledCommand("\(moduleID)/\(command)")
                }
            }
        }
        for service in manifest.macOSServices where service.owner.hasPrefix("switchboard:") {
            let workflow = resourcesURL.appending(path: "Services/\(service.name)", directoryHint: .isDirectory)
            let values = try workflow.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: workflow.appending(path: "Contents/Info.plist").path),
                  FileManager.default.fileExists(atPath: workflow.appending(path: "Contents/document.wflow").path) else {
                throw SelfTestError.missingBundledService(service.name)
            }
        }

        try validateCopyPathExtension(bundleURL: Bundle.main.bundleURL)
        try validateAgentProcessPolicy(bundleURL: Bundle.main.bundleURL)

        let contract = try JSONDecoder().decode(
            WarmCornersMigrationContract.self,
            from: Data(contentsOf: contractURL)
        )
        guard contract.schemaVersion == 1,
              contract.componentID == "desktop.warm-corners",
              !contract.pilot,
              contract.legacy.bundleID == "com.ivogundlach.WarmCorners",
              contract.replacement.bundleID == "com.ivogundlach.switchboard",
              contract.replacement.moduleID == contract.componentID,
              !contract.healthChecks.isEmpty,
              !contract.stabilizationTriggers.isEmpty,
              !contract.dataContract.snapshot.isEmpty,
              !contract.retirement.restoreSource.isEmpty else {
            throw SelfTestError.invalidPilotContract
        }
    }

    private static func validateAgentProcessPolicy(bundleURL: URL) throws {
        let plistURL = bundleURL.appending(
            path: "Contents/Library/LaunchAgents/com.ivogundlach.switchboard.agent.plist"
        )
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), options: [], format: nil
        ) as? [String: Any]
        guard info?["Label"] as? String == "com.ivogundlach.switchboard.agent",
              info?["ProcessType"] as? String == "Standard",
              info?["RunAtLoad"] as? Bool == true,
              info?["KeepAlive"] as? Bool == true else {
            throw SelfTestError.invalidAgentProcessPolicy
        }
    }

    private static func validateCopyPathExtension(bundleURL: URL) throws {
        let appex = bundleURL
            .appending(path: "Contents/PlugIns/CopyPathFinderExt.appex", directoryHint: .isDirectory)
        let values = try appex.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SelfTestError.missingCopyPathExtension
        }
        let infoURL = appex.appending(path: "Contents/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == CopyPathController.extensionIdentifier,
              info?["CFBundleExecutable"] as? String == "CopyPathFinderExt",
              info?["NSExtension"] is [String: Any] else {
            throw SelfTestError.invalidCopyPathExtension
        }
        let executable = appex.appending(path: "Contents/MacOS/CopyPathFinderExt")
        let executableValues = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey])
        guard executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true,
              executableValues.isExecutable == true else {
            throw SelfTestError.missingCopyPathExtension
        }
        let entitlementsURL = appex.appending(path: "Contents/Resources/CopyPathFinderExt.entitlements")
        let entitlementData = try Data(contentsOf: entitlementsURL)
        let entitlements = try PropertyListSerialization.propertyList(from: entitlementData, options: [], format: nil) as? [String: Any]
        guard entitlements?["com.apple.security.app-sandbox"] as? Bool == true else {
            throw SelfTestError.invalidCopyPathExtension
        }
    }

    private static func validateKineticsBoundary(
        manifest: ModuleManifest,
        runtime: RuntimeManifest,
        bundleURL: URL
    ) throws {
        guard let module = manifest.modules.first(where: { $0.id == KineticsCompanionController.moduleID }),
              module.availability == .ready,
              module.components == ["nested Kinetics companion", "migration-only inert LoginLauncher helper", "Switchboard continuous agent job"],
              module.legacyLabels.isEmpty,
              module.legacyBundleIDs.contains(KineticsCompanionController.bundleIdentifier),
              module.legacyBundleIDs.contains("com.ivogundlach.Kinetics.LoginLauncher") else {
            throw SelfTestError.kineticsManifestBoundary
        }
        guard manifest.scheduledComponents.contains(where: {
            $0.label == KineticsLegacyLoginMigration.helperBundleIdentifier
                && $0.owner == "switchboard:desktop.kinetics"
                && $0.cadence.contains("never registered")
        }) else {
            throw SelfTestError.kineticsManifestBoundary
        }
        let jobs = runtime.jobs.filter { $0.moduleID == KineticsCompanionController.moduleID }
        guard jobs.count == 1,
              jobs[0].label == "com.ivogundlach.Kinetics",
              jobs[0].executable == "Companions/Kinetics.app/Contents/MacOS/Kinetics",
              jobs[0].arguments == ["--login"],
              jobs[0].schedule.kind == .continuous else {
            throw SelfTestError.kineticsManifestBoundary
        }
        let executableURL: URL
        do {
            executableURL = try KineticsCompanionController.validate(bundleURL: bundleURL)
        } catch {
            throw SelfTestError.missingKineticsCompanion
        }
        let iconURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/AppIcon.icns")
        let iconValues = try iconURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard iconValues.isRegularFile == true,
              iconValues.isSymbolicLink != true,
              (iconValues.fileSize ?? 0) > 0 else {
            throw SelfTestError.missingKineticsCompanion
        }
        try validateKineticsMigrationHelper(bundleURL: bundleURL)
    }

    private static func validateKineticsMigrationHelper(bundleURL: URL) throws {
        let helper = bundleURL.appending(
            path: "Contents/Library/LoginItems/Kinetics Login Launcher.app",
            directoryHint: .isDirectory
        )
        let values = try helper.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SelfTestError.missingKineticsMigrationHelper
        }
        let infoURL = helper.appending(path: "Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), options: [], format: nil
        ) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == KineticsLegacyLoginMigration.helperBundleIdentifier,
              info?["CFBundleExecutable"] as? String == "Kinetics Login Launcher",
              info?["LSBackgroundOnly"] as? Bool == true,
              info?["LSUIElement"] as? Bool == true,
              info?["LSMinimumSystemVersion"] as? String == "26.0" else {
            throw SelfTestError.invalidKineticsMigrationHelper
        }
        let executable = helper.appending(path: "Contents/MacOS/Kinetics Login Launcher")
        let executableValues = try executable.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
        )
        guard executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true,
              executableValues.isExecutable == true else {
            throw SelfTestError.missingKineticsMigrationHelper
        }
    }
}

struct InventoryBaseline: Decodable {
    let schemaVersion: Int
    let moduleIDs: [String]
    let scheduledLabels: [String]
    let commandItems: [String]
    let memoryToolCandidates: [String]
    let macOSServices: [String]
    let standaloneProducts: [String]
    let safariApps: [String]
    let dispositionItems: [String]

    func validate(_ manifest: ModuleManifest) throws {
        guard schemaVersion == 1,
              moduleIDs == manifest.modules.map(\.id).sorted(),
              scheduledLabels == manifest.scheduledComponents.map(\.label).sorted(),
              commandItems == manifest.ownedCommandFamilies.flatMap(\.items).sorted(),
              memoryToolCandidates == manifest.memoryToolCandidates.sorted(),
              macOSServices == manifest.macOSServices.map(\.name).sorted(),
              standaloneProducts == manifest.standaloneProducts.map(\.name).sorted(),
              safariApps == manifest.separateSafariApps.sorted(),
              dispositionItems == (
                manifest.excludedShortcuts + manifest.replacedShortcuts
                + manifest.excludedThirdPartyUtilities + manifest.excludedSupersededOrDeleted
              ).map(\.name).sorted() else {
            throw SelfTestError.inventoryBaselineMismatch
        }
    }
}

enum ManifestValidator {
    private static let requiredStandalone = Set([
        "Market", "School", "Tool Dashboard", "Vitals", "UsageQueue",
        "ReleaseRadar", "NutrientTracker", "Psephos", "Tax Simulator", "Runway",
    ])
    private static let requiredSafari = Set(["ForceCopyPaste", "NewTabLinks", "YouTube Defaults"])
    private static let requiredBrightnessShortcuts = Set(["Set Mac Day Brightness", "Set Mac Night brightness"])

    static func validate(_ manifest: ModuleManifest) throws {
        guard manifest.schemaVersion == 1 else { throw SelfTestError.unsupportedSchema }
        let moduleIDs = Set(manifest.modules.map(\.id))
        guard moduleIDs.count == manifest.modules.count else { throw SelfTestError.duplicateModuleID }
        guard manifest.modules.filter({ $0.availability == .pilot }).isEmpty else {
            throw SelfTestError.invalidPilotSet
        }

        let moduleNames = Set(manifest.modules.map(\.name))
        let standaloneNames = Set(manifest.standaloneProducts.map(\.name))
        guard standaloneNames == requiredStandalone,
              moduleNames.isDisjoint(with: standaloneNames) else {
            throw SelfTestError.ownershipOverlap
        }
        guard Set(manifest.separateSafariApps) == requiredSafari,
              moduleNames.isDisjoint(with: requiredSafari) else {
            throw SelfTestError.safariOverlap
        }
        guard Set(manifest.replacedShortcuts.map(\.name)) == requiredBrightnessShortcuts,
              Set(manifest.excludedShortcuts.map(\.name)).isDisjoint(with: requiredBrightnessShortcuts) else {
            throw SelfTestError.shortcutBoundary
        }

        for owner in manifest.scheduledComponents.map(\.owner)
            + manifest.ownedCommandFamilies.map(\.owner)
            + manifest.macOSServices.map(\.owner)
            + manifest.excludedShortcuts.map(\.owner)
            + manifest.replacedShortcuts.map(\.owner)
            + manifest.excludedThirdPartyUtilities.map(\.owner)
            + manifest.excludedSupersededOrDeleted.map(\.owner) {
            try validateOwner(owner, moduleIDs: moduleIDs, standaloneNames: standaloneNames)
        }

        let scheduledLabels = manifest.scheduledComponents.map(\.label)
        guard Set(scheduledLabels).count == scheduledLabels.count else {
            throw SelfTestError.duplicateOwnedItem
        }

        let commands = manifest.ownedCommandFamilies.flatMap(\.items)
        let memoryTools = manifest.memoryToolCandidates
        let services = manifest.macOSServices.map(\.name)
        let dispositionNames = manifest.excludedShortcuts.map(\.name)
            + manifest.replacedShortcuts.map(\.name)
            + manifest.excludedThirdPartyUtilities.map(\.name)
            + manifest.excludedSupersededOrDeleted.map(\.name)
        let everyOwnedItem = commands + memoryTools + services + dispositionNames
        guard Set(everyOwnedItem).count == everyOwnedItem.count else {
            throw SelfTestError.duplicateOwnedItem
        }

        let requiredStandaloneJobs: [String: String] = [
            "com.ivo.market.refresh": "standalone:Market",
            "com.ivo.school-sync": "standalone:School",
            "com.ivogundlach.tool-status-dashboard.repair": "standalone:Tool Dashboard",
            "com.ivogundlach.tool-status-dashboard.scan": "standalone:Tool Dashboard",
            "com.ivogundlach.vitals.findings": "standalone:Vitals",
            "com.ivogundlach.vitals.sampler": "standalone:Vitals",
            "com.ivogundlach.vitals.helper": "standalone:Vitals",
        ]
        let jobsByLabel = Dictionary(uniqueKeysWithValues: manifest.scheduledComponents.map { ($0.label, $0.owner) })
        guard requiredStandaloneJobs.allSatisfy({ jobsByLabel[$0.key] == $0.value }) else {
            throw SelfTestError.standaloneWorkerBoundary
        }
    }

    private static func validateOwner(
        _ owner: String,
        moduleIDs: Set<String>,
        standaloneNames: Set<String>
    ) throws {
        if owner.hasPrefix("switchboard:") {
            guard moduleIDs.contains(String(owner.dropFirst("switchboard:".count))) else {
                throw SelfTestError.invalidOwnerReference
            }
            return
        }
        if owner.hasPrefix("standalone:") {
            guard standaloneNames.contains(String(owner.dropFirst("standalone:".count))) else {
                throw SelfTestError.invalidOwnerReference
            }
            return
        }
        if owner.hasPrefix("excluded:") { return }
        throw SelfTestError.invalidOwnerReference
    }
}

struct WarmCornersMigrationContract: Decodable {
    struct Legacy: Decodable { let bundleID: String }
    struct Replacement: Decodable { let bundleID: String; let moduleID: String }
    struct DataContract: Decodable { let snapshot: String }
    struct Retirement: Decodable { let restoreSource: String }

    let schemaVersion: Int
    let componentID: String
    let pilot: Bool
    let legacy: Legacy
    let replacement: Replacement
    let dataContract: DataContract
    let healthChecks: [String]
    let stabilizationTriggers: [String]
    let retirement: Retirement
}

enum SelfTestError: LocalizedError {
    case missingResource
    case unsupportedSchema
    case duplicateModuleID
    case ownershipOverlap
    case safariOverlap
    case invalidPilotSet
    case invalidPilotContract
    case smartWakeReadiness
    case shortcutBoundary
    case duplicateOwnedItem
    case invalidOwnerReference
    case standaloneWorkerBoundary
    case inventoryBaselineMismatch
    case runtimeOwnershipMismatch
    case missingRuntimeExecutable(String)
    case missingBundledCommand(String)
    case missingBundledService(String)
    case missingCopyPathExtension
    case invalidCopyPathExtension
    case kineticsManifestBoundary
    case missingKineticsCompanion
    case missingKineticsMigrationHelper
    case invalidKineticsMigrationHelper
    case invalidAgentProcessPolicy

    var errorDescription: String? {
        switch self {
        case .missingResource: "A required bundled resource is missing."
        case .unsupportedSchema: "The module manifest schema is unsupported."
        case .duplicateModuleID: "The module manifest contains a duplicate ID."
        case .ownershipOverlap: "A standalone product was also assigned to Switchboard."
        case .safariOverlap: "A separate Safari app was also assigned to Switchboard."
        case .invalidPilotSet: "No pilot modules may remain in the production catalog."
        case .invalidPilotContract: "The Warm Corners production migration contract is invalid."
        case .smartWakeReadiness: "Smart Wake core readiness or legacy scheduler boundaries are invalid."
        case .shortcutBoundary: "The Apple Shortcut boundary is invalid."
        case .duplicateOwnedItem: "A process, command, tool, or service has more than one owner."
        case .invalidOwnerReference: "A component refers to an unknown owner."
        case .standaloneWorkerBoundary: "A standalone worker is assigned to the wrong owner."
        case .inventoryBaselineMismatch: "The manifest does not match the locked inventory baseline."
        case .runtimeOwnershipMismatch: "A runtime job is assigned to the wrong module owner."
        case .missingRuntimeExecutable(let label): "The bundled runtime executable for \(label) is missing."
        case .missingBundledCommand(let name): "The bundled command \(name) is missing or unsafe."
        case .missingBundledService(let name): "The bundled macOS Service \(name) is missing or unsafe."
        case .missingCopyPathExtension: "The bundled Copy Path Finder Sync extension is missing or unsafe."
        case .invalidCopyPathExtension: "The bundled Copy Path Finder Sync extension identity or entitlement is invalid."
        case .kineticsManifestBoundary: "The Kinetics module or continuous agent boundary is invalid."
        case .missingKineticsCompanion: "The nested Kinetics companion is missing or unsafe."
        case .missingKineticsMigrationHelper: "The inert Kinetics migration helper is missing or unsafe."
        case .invalidKineticsMigrationHelper: "The inert Kinetics migration helper identity or background settings are invalid."
        case .invalidAgentProcessPolicy: "The Switchboard agent process policy is invalid."
        }
    }
}
