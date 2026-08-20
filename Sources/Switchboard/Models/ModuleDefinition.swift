import Foundation

struct ModuleManifest: Decodable {
    let schemaVersion: Int
    let supportedPlatform: String
    let modules: [ModuleDefinition]
    let scheduledComponents: [ScheduledComponent]
    let ownedCommandFamilies: [OwnedCommandFamily]
    let memoryToolCandidates: [String]
    let macOSServices: [OwnedService]
    let standaloneProducts: [StandaloneProduct]
    let separateSafariApps: [String]
    let excludedShortcuts: [InventoryDisposition]
    let replacedShortcuts: [InventoryDisposition]
    let excludedThirdPartyUtilities: [InventoryDisposition]
    let excludedSupersededOrDeleted: [InventoryDisposition]
}

struct ScheduledComponent: Decodable, Identifiable, Hashable {
    let label: String
    let owner: String
    let cadence: String
    var id: String { label }
}

struct OwnedCommandFamily: Decodable, Identifiable, Hashable {
    let owner: String
    let items: [String]
    var id: String { owner }
}

struct OwnedService: Decodable, Identifiable, Hashable {
    let name: String
    let owner: String
    var id: String { name }
}

struct InventoryDisposition: Decodable, Identifiable, Hashable {
    let name: String
    let owner: String
    let disposition: String
    var id: String { name }
}

struct ModuleDefinition: Decodable, Identifiable, Hashable {
    enum Owner: String, Decodable {
        case switchboard
    }

    enum Availability: String, Decodable {
        case pilot
        case ready
        case planned
        case repairRequired = "repair-required"
        case classificationRequired = "classification-required"

        var label: String {
            switch self {
            case .pilot: "Pilot ready"
            case .ready: "Ready"
            case .planned: "Planned"
            case .repairRequired: "Repair required"
            case .classificationRequired: "Inventory review"
            }
        }
    }

    let id: String
    let name: String
    let group: String
    let purpose: String
    let owner: Owner
    let availability: Availability
    let components: [String]
    let permissionCategories: [String]
    let legacyLabels: [String]
    let legacyBundleIDs: [String]
    let configKeys: [String]
}

struct StandaloneProduct: Decodable, Identifiable, Hashable {
    let name: String
    let workers: [String]
    var id: String { name }
}

enum ModuleHealth: Equatable {
    case ready(String)
    case disabled(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .ready(let text), .disabled(let text), .unavailable(let text): text
        }
    }
}
