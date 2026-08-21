import Foundation

struct UpgradeMigrationContract: Codable, Equatable {
    let schemaVersion: Int
    let modules: [UpgradeMigrationModule]

    static let currentSchemaVersion = 1

    static func load(from url: URL, moduleIDs: Set<String>) throws -> UpgradeMigrationContract {
        let contract = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try contract.validate(against: moduleIDs)
        return contract
    }

    func validate(against moduleIDs: Set<String>) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw UpgradeMigrationContractValidationError.invalidSchemaVersion(schemaVersion)
        }

        let actualModuleIDs = modules.map(\.moduleID)
        let actualSet = Set(actualModuleIDs)
        if actualModuleIDs.count != actualSet.count {
            throw UpgradeMigrationContractValidationError.duplicateModuleID
        }
        let missing = moduleIDs.subtracting(actualSet).sorted()
        if !missing.isEmpty {
            throw UpgradeMigrationContractValidationError.missingModuleIDs(missing)
        }
        let unknown = actualSet.subtracting(moduleIDs).sorted()
        if !unknown.isEmpty {
            throw UpgradeMigrationContractValidationError.unknownModuleIDs(unknown)
        }

        var componentIDs = Set<String>()
        var permissionIDs = Set<String>()
        for module in modules {
            for component in module.legacyComponents {
                guard componentIDs.insert(component.id).inserted else {
                    throw UpgradeMigrationContractValidationError.duplicateComponentID(component.id)
                }
                try component.validate(replacementHealth: module.replacementHealth)
            }
            for permission in module.permissions {
                guard permissionIDs.insert(permission.id).inserted else {
                    throw UpgradeMigrationContractValidationError.duplicatePermissionID(permission.id)
                }
                try permission.validate()
            }
        }
    }

    /// Convenience spelling for callers that want a validated copy.
    func validated(against moduleIDs: Set<String>) throws -> Self {
        try validate(against: moduleIDs)
        return self
    }
}

struct UpgradeMigrationModule: Codable, Equatable, Identifiable {
    let moduleID: String
    let settingsPolicy: UpgradeSettingsPolicy
    let replacementHealth: UpgradeReplacementHealth
    let legacyComponents: [UpgradeLegacyComponent]
    let permissions: [UpgradePermission]

    var id: String { moduleID }
}

enum UpgradeSettingsPolicy: String, Codable {
    case legacyOnce
    case sharedCanonical
}

enum UpgradeReplacementHealth: String, Codable {
    case verified
    case unverified
}

struct UpgradeLegacyComponent: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let kind: UpgradeLegacyComponentKind
    let disposition: UpgradeLegacyDisposition
    let canonicalPath: String?
    let bundleID: String?
    let executableName: String?
    let label: String?
    let defaultsDomain: String?
    let defaultsKey: String?

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, disposition, canonicalPath, bundleID, executableName, label
        case defaultsDomain, defaultsKey
    }

    init(
        id: String,
        displayName: String,
        kind: UpgradeLegacyComponentKind,
        disposition: UpgradeLegacyDisposition,
        canonicalPath: String? = nil,
        bundleID: String? = nil,
        executableName: String? = nil,
        label: String? = nil,
        defaultsDomain: String? = nil,
        defaultsKey: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.disposition = disposition
        self.canonicalPath = canonicalPath
        self.bundleID = bundleID
        self.executableName = executableName
        self.label = label
        self.defaultsDomain = defaultsDomain
        self.defaultsKey = defaultsKey
    }

    fileprivate func validate(replacementHealth: UpgradeReplacementHealth) throws {
        if disposition == .migrate && replacementHealth == .unverified {
            throw UpgradeMigrationContractValidationError.unverifiedReplacement(id)
        }
        if kind == .appBundle, let path = canonicalPath, !Self.isSafeAppPath(path) {
            throw UpgradeMigrationContractValidationError.unsafeAppPath(path)
        }
        guard disposition == .migrate else { return }
        switch kind {
        case .appBundle:
            guard canonicalPath != nil, bundleID != nil, executableName != nil else {
                throw UpgradeMigrationContractValidationError.incompleteAppMigration(id)
            }
        case .launchAgent, .cron:
            guard let label, !label.isEmpty else {
                throw UpgradeMigrationContractValidationError.missingSchedulerLabel(id)
            }
        case .command, .service, .preference, .shortcut:
            break
        }
    }

    static func isSafeAppPath(_ path: String) -> Bool {
        guard path.hasPrefix("/Applications/") else { return false }
        let name = String(path.dropFirst("/Applications/".count))
        guard name.hasSuffix(".app"), name.count > 4 else { return false }
        let stem = name.dropLast(4)
        return !stem.isEmpty && !stem.contains("/") && stem != "." && stem != ".."
    }
}

enum UpgradeLegacyComponentKind: String, Codable {
    case appBundle
    case launchAgent
    case cron
    case command
    case service
    case preference
    case shortcut
}

enum UpgradeLegacyDisposition: String, Codable {
    case migrate
    case retain
    case alreadyRetired
}

struct UpgradePermission: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let subject: String
    let mechanism: UpgradePermissionMechanism
    let subjectRelativePath: String?
    let settingsURL: String?
    let targetBundleID: String?
    let detail: String

    private enum CodingKeys: String, CodingKey {
        case id, displayName, subject, mechanism, subjectRelativePath, settingsURL, targetBundleID, detail
    }

    init(
        id: String,
        displayName: String,
        subject: String,
        mechanism: UpgradePermissionMechanism,
        subjectRelativePath: String? = nil,
        settingsURL: String? = nil,
        targetBundleID: String? = nil,
        detail: String
    ) {
        self.id = id
        self.displayName = displayName
        self.subject = subject
        self.mechanism = mechanism
        self.subjectRelativePath = subjectRelativePath
        self.settingsURL = settingsURL
        self.targetBundleID = targetBundleID
        self.detail = detail
    }

    fileprivate func validate() throws {
        switch mechanism {
        case .accessibilityHelper, .fullDiskAccessHelper:
            guard let path = subjectRelativePath, !path.isEmpty else {
                throw UpgradeMigrationContractValidationError.missingPermissionSubjectPath(id)
            }
        case .runtimePrompt:
            guard let targetBundleID, !targetBundleID.isEmpty else {
                throw UpgradeMigrationContractValidationError.missingPermissionTarget(id)
            }
        case .appManagementAttestation, .finderExtension, .externalHost:
            break
        }
    }
}

enum UpgradePermissionMechanism: String, Codable {
    case accessibilityHelper
    case fullDiskAccessHelper
    case appManagementAttestation
    case finderExtension
    case runtimePrompt
    case externalHost
}

enum UpgradeMigrationContractValidationError: Error, Equatable, LocalizedError {
    case invalidSchemaVersion(Int)
    case duplicateModuleID
    case missingModuleIDs([String])
    case unknownModuleIDs([String])
    case duplicateComponentID(String)
    case incompleteAppMigration(String)
    case missingSchedulerLabel(String)
    case unsafeAppPath(String)
    case unverifiedReplacement(String)
    case duplicatePermissionID(String)
    case missingPermissionSubjectPath(String)
    case missingPermissionTarget(String)

    var errorDescription: String? {
        switch self {
        case .invalidSchemaVersion(let value): "Unsupported upgrade contract schema version: \(value)."
        case .duplicateModuleID: "The upgrade contract contains a duplicate module ID."
        case .missingModuleIDs(let ids): "The upgrade contract is missing module IDs: \(ids.joined(separator: ", "))."
        case .unknownModuleIDs(let ids): "The upgrade contract contains unknown module IDs: \(ids.joined(separator: ", "))."
        case .duplicateComponentID(let id): "The upgrade contract contains duplicate component ID \(id)."
        case .incompleteAppMigration(let id): "Migrated app component \(id) must declare canonicalPath, bundleID, and executableName."
        case .missingSchedulerLabel(let id): "Migrated scheduler component \(id) must declare label."
        case .unsafeAppPath(let path): "App bundle path is not a safe /Applications/<name>.app path: \(path)."
        case .unverifiedReplacement(let id): "Migrated component \(id) has an unverified replacement."
        case .duplicatePermissionID(let id): "The upgrade contract contains duplicate permission ID \(id)."
        case .missingPermissionSubjectPath(let id): "Permission \(id) must declare subjectRelativePath."
        case .missingPermissionTarget(let id): "Permission \(id) must declare targetBundleID."
        }
    }
}
