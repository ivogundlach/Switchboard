import Foundation

enum AutomaticUpgradePhase: String, Codable, Equatable {
    case scanned
    case waitingForPermissions
    case running
    case completed
    case completedWithIssues
    case failed
}

struct AutomaticUpgradeComponentRecord: Codable, Equatable, Identifiable {
    let moduleID: String
    let componentID: String
    let displayName: String
    let kind: UpgradeLegacyComponentKind
    let disposition: UpgradeLegacyDisposition
    let detection: LegacyUpgradeDetection
    let detail: String

    var id: String { componentID }
}

struct AutomaticUpgradeStatus: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    var updatedAt: Date
    var phase: AutomaticUpgradePhase
    let selectedModuleIDs: [String]
    let components: [AutomaticUpgradeComponentRecord]
    var permissionBlockers: [String]
    var moduleResults: [String: String]
    var failure: String?
}

enum AutomaticUpgradePolicy {
    static func selectedModuleIDs(from plan: LegacyUpgradeReviewPlan) -> Set<String> {
        Set(plan.modules.filter(\.recommendedSelected).map(\.module.id))
    }

    static func componentRecords(from plan: LegacyUpgradeReviewPlan) -> [AutomaticUpgradeComponentRecord] {
        plan.modules.flatMap { review in
            review.components.map { evidence in
                AutomaticUpgradeComponentRecord(
                    moduleID: review.module.id,
                    componentID: evidence.component.id,
                    displayName: evidence.component.displayName,
                    kind: evidence.component.kind,
                    disposition: evidence.component.disposition,
                    detection: evidence.detection,
                    detail: evidence.detail
                )
            }
        }
    }
}

struct AutomaticUpgradeStatusStore {
    let fileURL: URL

    init(applicationSupportURL: URL) {
        fileURL = applicationSupportURL.appending(path: "automatic-upgrade-status.json")
    }

    func save(_ status: AutomaticUpgradeStatus) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let temporary = directory.appending(path: ".automatic-upgrade-status-\(UUID().uuidString).tmp")
        try encoder.encode(status).write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}
