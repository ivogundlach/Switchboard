import Foundation

@MainActor
final class WarmCornersMigrationService {
    typealias LegacyDataProvider = () -> Data?
    typealias LegacyQuiescence = () throws -> LegacyQuiescenceEvidence
    typealias LegacyStatusProvider = () throws -> LegacyQuiescenceEvidence

    private let settings: WarmCornerSettings
    private let coordinator: OperationCoordinator
    private let ledger: MigrationLedger
    private let recoveryStore: RecoveryStore
    private let legacyDataProvider: LegacyDataProvider
    private let quiesceLegacy: LegacyQuiescence?
    private let legacyStatusProvider: LegacyStatusProvider?

    init(
        settings: WarmCornerSettings,
        coordinator: OperationCoordinator,
        ledger: MigrationLedger,
        recoveryStore: RecoveryStore,
        legacyDataProvider: @escaping LegacyDataProvider = {
            UserDefaults(suiteName: "com.ivogundlach.WarmCorners")?
                .data(forKey: "warmcorners.config")
        },
        quiesceLegacy: LegacyQuiescence? = nil,
        legacyStatusProvider: LegacyStatusProvider? = nil
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.ledger = ledger
        self.recoveryStore = recoveryStore
        self.legacyDataProvider = legacyDataProvider
        self.quiesceLegacy = quiesceLegacy
        self.legacyStatusProvider = legacyStatusProvider
    }

    /// Imports only after the production migration supplies a verified way to
    /// stop the legacy watcher. Until then, existing users fail closed instead
    /// of silently copying settings outside the transaction ledger.
    func importLegacyIfNeeded() async throws -> Bool {
        guard let legacyData = legacyDataProvider() else { return false }
        if settings.hasStoredConfiguration {
            guard let legacyStatusProvider else {
                throw WarmCornersMigrationError.legacyQuiescenceUnavailable
            }
            guard try legacyStatusProvider().isVerified else {
                throw WarmCornersMigrationError.legacyQuiescenceUnverified
            }
            return false
        }
        guard let payload = WarmCornerSettingsCodec.decode(legacyData) else {
            throw WarmCornersMigrationError.invalidLegacySettings
        }
        guard let quiesceLegacy else {
            throw WarmCornersMigrationError.legacyQuiescenceUnavailable
        }

        return try await coordinator.perform(.migration) {
            var records = try ledger.load()
            var record = MigrationRecord(componentID: "desktop.warm-corners")
            records.append(record)
            try ledger.save(records)

            do {
                try record.transition(to: .preflighted, note: "Legacy settings decoded")
                try replace(record, in: &records)

                try record.transition(to: .snapshotting, note: "Preparing exact recovery snapshot")
                try replace(record, in: &records)
                let artifact = try recoveryStore.snapshot(
                    data: legacyData,
                    name: "warm-corners-settings.json",
                    transactionID: record.id
                )
                record.recoveryArtifact = artifact
                try record.transition(to: .snapshotted, note: "Exact legacy settings snapshot verified")
                try replace(record, in: &records)

                try record.transition(to: .quiescing, note: "Preparing to stop legacy pointer watcher")
                try replace(record, in: &records)
                let evidence = try quiesceLegacy()
                guard evidence.isVerified else {
                    throw WarmCornersMigrationError.legacyQuiescenceUnverified
                }
                try record.transition(to: .quiesced, note: "Legacy pointer watcher stopped")
                try replace(record, in: &records)

                try record.transition(to: .installingReplacement, note: "Preparing to import settings")
                try replace(record, in: &records)
                settings.applyImportedPayload(payload)
                try record.transition(to: .replacementInstalled, note: "Settings imported into Switchboard")
                try record.transition(to: .replacementRegistered, note: "Warm Corners module prepared")
                guard settings.encodedData().flatMap(WarmCornerSettingsCodec.decode) == payload else {
                    throw WarmCornersMigrationError.importVerificationFailed
                }
                try record.transition(to: .healthVerified, note: "Imported settings round-trip verified")
                try record.transition(to: .stabilizing, note: "Awaiting production trigger checks")
                try replace(record, in: &records)
                return true
            } catch {
                if record.state.canTransition(to: .rollingBack) {
                    try? record.transition(to: .rollingBack, note: "Import failed; clearing replacement settings")
                    try? replace(record, in: &records)
                    settings.clearStoredConfiguration()
                    try? record.transition(to: .rolledBack, note: "Replacement settings cleared; legacy source preserved")
                    try? replace(record, in: &records)
                } else {
                    try? record.transition(to: .failed, note: "Import failed before replacement settings were written")
                    try? replace(record, in: &records)
                }
                throw error
            }
        }
    }

    private func replace(_ record: MigrationRecord, in records: inout [MigrationRecord]) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            throw WarmCornersMigrationError.missingTransaction
        }
        records[index] = record
        try ledger.save(records)
    }
}

struct LegacyQuiescenceEvidence: Equatable {
    let watcherProcessAbsent: Bool
    let loginRegistrationDisabled: Bool

    var isVerified: Bool {
        watcherProcessAbsent && loginRegistrationDisabled
    }

    static let verified = LegacyQuiescenceEvidence(
        watcherProcessAbsent: true,
        loginRegistrationDisabled: true
    )
}

enum WarmCornersMigrationError: LocalizedError {
    case invalidLegacySettings
    case legacyQuiescenceUnavailable
    case legacyQuiescenceUnverified
    case importVerificationFailed
    case missingTransaction

    var errorDescription: String? {
        switch self {
        case .invalidLegacySettings: "Legacy Warm Corners settings are invalid."
        case .legacyQuiescenceUnavailable: "The legacy Warm Corners watcher cannot yet be stopped safely."
        case .legacyQuiescenceUnverified: "The legacy Warm Corners watcher or login registration is still active."
        case .importVerificationFailed: "Imported Warm Corners settings did not verify."
        case .missingTransaction: "The Warm Corners migration transaction is missing."
        }
    }
}
