import Foundation

enum SelfTest {
    static func run() throws {
        guard let manifestURL = Bundle.main.url(forResource: "ModuleManifest", withExtension: "json"),
              let contractURL = Bundle.main.url(forResource: "WarmCornersMigrationContract", withExtension: "json"),
              let baselineURL = Bundle.main.url(forResource: "InventoryBaseline", withExtension: "json") else {
            throw SelfTestError.missingResource
        }

        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: manifestURL))
        try ManifestValidator.validate(manifest)
        let baseline = try JSONDecoder().decode(InventoryBaseline.self, from: Data(contentsOf: baselineURL))
        try baseline.validate(manifest)

        let contract = try JSONDecoder().decode(
            WarmCornersMigrationContract.self,
            from: Data(contentsOf: contractURL)
        )
        guard contract.schemaVersion == 1,
              contract.componentID == "desktop.warm-corners",
              contract.pilot,
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
        guard manifest.modules.filter({ $0.availability == .pilot }).map(\.id) == ["desktop.warm-corners"] else {
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
    case shortcutBoundary
    case duplicateOwnedItem
    case invalidOwnerReference
    case standaloneWorkerBoundary
    case inventoryBaselineMismatch

    var errorDescription: String? {
        switch self {
        case .missingResource: "A required bundled resource is missing."
        case .unsupportedSchema: "The module manifest schema is unsupported."
        case .duplicateModuleID: "The module manifest contains a duplicate ID."
        case .ownershipOverlap: "A standalone product was also assigned to Switchboard."
        case .safariOverlap: "A separate Safari app was also assigned to Switchboard."
        case .invalidPilotSet: "Warm Corners must be the only pilot module."
        case .invalidPilotContract: "The Warm Corners migration contract is invalid."
        case .shortcutBoundary: "The Apple Shortcut boundary is invalid."
        case .duplicateOwnedItem: "A process, command, tool, or service has more than one owner."
        case .invalidOwnerReference: "A component refers to an unknown owner."
        case .standaloneWorkerBoundary: "A standalone worker is assigned to the wrong owner."
        case .inventoryBaselineMismatch: "The manifest does not match the locked inventory baseline."
        }
    }
}
