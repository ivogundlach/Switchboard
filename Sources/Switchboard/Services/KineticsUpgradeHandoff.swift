import Foundation

enum KineticsUpgradeHandoffPhase: String, Codable {
    case planned
    case stopIntent
    case legacyStopped
    case replacementSelected
    case replacementHealthy
    case legacyLoginRetirementIntent
    case legacyLoginRetired
    case committed
    case rolledBack
}

enum KineticsUpgradeRecoveryAction: Equatable {
    case rollbackToLegacy
    case keepReplacementPending
    case none

    static func decide(
        phase: KineticsUpgradeHandoffPhase,
        legacyLoginStatus: KineticsLegacyLoginStatus
    ) -> Self {
        switch phase {
        case .planned, .stopIntent, .legacyStopped, .replacementSelected, .replacementHealthy:
            return .rollbackToLegacy
        case .legacyLoginRetirementIntent:
            switch legacyLoginStatus {
            case .enabled, .requiresApproval:
                return .rollbackToLegacy
            case .notRegistered, .notFound, .unknown:
                return .keepReplacementPending
            }
        case .legacyLoginRetired:
            return .keepReplacementPending
        case .committed, .rolledBack:
            return .none
        }
    }
}

struct KineticsUpgradeHandoffRecord: Codable, Equatable {
    let schemaVersion: Int
    let transactionID: UUID
    let healthNonce: String
    let legacyAppPath: String
    let legacyExecutableName: String
    let legacyWasRunning: Bool
    let priorSelection: [String]
    var phase: KineticsUpgradeHandoffPhase
}

final class KineticsUpgradeHandoffStore {
    private let fileManager: FileManager
    let fileURL: URL

    init(
        supportURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Switchboard", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        fileURL = supportURL.appending(path: "Upgrade/kinetics-handoff.json")
    }

    func begin(
        healthNonce: String,
        legacyAppPath: String,
        legacyExecutableName: String,
        legacyWasRunning: Bool,
        priorSelection: Set<String>
    ) throws -> KineticsUpgradeHandoffRecord {
        let record = KineticsUpgradeHandoffRecord(
            schemaVersion: 1,
            transactionID: UUID(),
            healthNonce: healthNonce,
            legacyAppPath: legacyAppPath,
            legacyExecutableName: legacyExecutableName,
            legacyWasRunning: legacyWasRunning,
            priorSelection: priorSelection.sorted(),
            phase: .planned
        )
        try persist(record)
        return record
    }

    func load() throws -> KineticsUpgradeHandoffRecord? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0 else {
            throw KineticsUpgradeHandoffError.unsafeJournal
        }
        let record = try JSONDecoder().decode(
            KineticsUpgradeHandoffRecord.self,
            from: Data(contentsOf: fileURL)
        )
        guard record.schemaVersion == 1,
              record.legacyAppPath == "/Applications/Kinetics.app",
              record.legacyExecutableName == "Kinetics",
              UUID(uuidString: record.healthNonce) != nil else {
            throw KineticsUpgradeHandoffError.unsafeJournal
        }
        return record
    }

    func transition(
        _ record: KineticsUpgradeHandoffRecord,
        to phase: KineticsUpgradeHandoffPhase
    ) throws -> KineticsUpgradeHandoffRecord {
        let allowed: Set<String> = [
            "planned>stopIntent", "planned>rolledBack",
            "stopIntent>legacyStopped", "stopIntent>rolledBack",
            "legacyStopped>replacementSelected", "legacyStopped>rolledBack",
            "replacementSelected>replacementHealthy", "replacementSelected>rolledBack",
            "replacementHealthy>legacyLoginRetirementIntent", "replacementHealthy>rolledBack",
            "legacyLoginRetirementIntent>legacyLoginRetired", "legacyLoginRetirementIntent>rolledBack",
            "legacyLoginRetired>committed", "legacyLoginRetired>rolledBack",
        ]
        guard allowed.contains("\(record.phase.rawValue)>\(phase.rawValue)") else {
            throw KineticsUpgradeHandoffError.invalidTransition
        }
        var updated = record
        updated.phase = phase
        try persist(updated)
        return updated
    }

    private func persist(_ record: KineticsUpgradeHandoffRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        let support = directory.deletingLastPathComponent()
        try ensureOwnerOnlyDirectory(support, createIntermediates: true)
        try ensureOwnerOnlyDirectory(directory, createIntermediates: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func ensureOwnerOnlyDirectory(_ url: URL, createIntermediates: Bool) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediates,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw KineticsUpgradeHandoffError.unsafeJournal
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

enum KineticsUpgradeHandoffError: LocalizedError {
    case unsafeJournal
    case invalidTransition
    var errorDescription: String? {
        switch self {
        case .unsafeJournal: "The Kinetics upgrade handoff journal is unsafe or malformed."
        case .invalidTransition: "The Kinetics upgrade handoff tried to skip a required recovery state."
        }
    }
}
