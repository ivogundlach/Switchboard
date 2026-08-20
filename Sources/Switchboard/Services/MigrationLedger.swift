import Foundation
import CryptoKit

enum MigrationState: String, Codable, CaseIterable {
    case planned
    case preflighted
    case snapshotting
    case snapshotted
    case quiescing
    case quiesced
    case installingReplacement
    case replacementInstalled
    case replacementRegistered
    case healthVerified
    case stabilizing
    case retired
    case rollingBack
    case rolledBack
    case failed

    func canTransition(to next: MigrationState) -> Bool {
        switch (self, next) {
        case (.planned, .preflighted),
             (.preflighted, .snapshotting),
             (.snapshotting, .snapshotted),
             (.snapshotted, .quiescing),
             (.quiescing, .quiesced),
             (.quiesced, .installingReplacement),
             (.installingReplacement, .replacementInstalled),
             (.replacementInstalled, .replacementRegistered),
             (.replacementRegistered, .healthVerified),
             (.healthVerified, .stabilizing),
             (.stabilizing, .retired),
             (.snapshotting, .rollingBack),
             (.snapshotted, .rollingBack),
             (.quiescing, .rollingBack),
             (.quiesced, .rollingBack),
             (.installingReplacement, .rollingBack),
             (.replacementInstalled, .rollingBack),
             (.replacementRegistered, .rollingBack),
             (.healthVerified, .rollingBack),
             (.stabilizing, .rollingBack),
             (.rollingBack, .rolledBack):
            true
        case (_, .failed):
            true
        default:
            false
        }
    }

    var needsRecoveryAfterInterruption: Bool {
        switch self {
        case .snapshotting, .snapshotted, .quiescing, .quiesced,
             .installingReplacement, .replacementInstalled,
             .replacementRegistered, .healthVerified, .stabilizing, .rollingBack:
            true
        default:
            false
        }
    }
}

struct MigrationEvent: Codable, Equatable {
    let state: MigrationState
    let timestamp: Date
    let note: String
}

struct MigrationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let componentID: String
    let createdAt: Date
    var state: MigrationState
    var events: [MigrationEvent]
    var oldArtifactSHA256: String?
    var newArtifactSHA256: String?
    var recoveryArtifact: RecoveryArtifact?

    init(componentID: String, now: Date = Date()) {
        id = UUID()
        self.componentID = componentID
        createdAt = now
        state = .planned
        events = [MigrationEvent(state: .planned, timestamp: now, note: "Transaction created")]
    }

    mutating func transition(to next: MigrationState, note: String, now: Date = Date()) throws {
        guard state.canTransition(to: next) else {
            throw MigrationLedgerError.invalidTransition(from: state, to: next)
        }
        state = next
        events.append(MigrationEvent(state: next, timestamp: now, note: note))
    }
}

enum MigrationLedgerError: LocalizedError {
    case invalidTransition(from: MigrationState, to: MigrationState)
    case unsafeLedgerPath
    case unsafeRecoveryName
    case recoveryIntegrityFailed

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            "Migration cannot move from \(from.rawValue) to \(to.rawValue)."
        case .unsafeLedgerPath:
            "Migration ledger path is not a safe regular-file location."
        case .unsafeRecoveryName:
            "Recovery artifact name is unsafe."
        case .recoveryIntegrityFailed:
            "Recovery artifact failed its integrity check."
        }
    }
}

struct RecoveryArtifact: Codable, Equatable {
    let relativePath: String
    let sha256: String
    let byteCount: Int
}

struct RecoveryStore {
    let rootURL: URL

    func snapshot(data: Data, name: String, transactionID: UUID) throws -> RecoveryArtifact {
        guard !name.isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else {
            throw MigrationLedgerError.unsafeRecoveryName
        }

        try ensureDirectory(rootURL)
        let transactionDirectory = rootURL.appending(path: transactionID.uuidString, directoryHint: .isDirectory)
        try ensureDirectory(transactionDirectory)
        let artifactURL = transactionDirectory.appending(path: name, directoryHint: .notDirectory)
        guard !FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw MigrationLedgerError.unsafeRecoveryName
        }

        try data.write(to: artifactURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifactURL.path)
        let values = try artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MigrationLedgerError.unsafeLedgerPath
        }

        return RecoveryArtifact(
            relativePath: "\(transactionID.uuidString)/\(name)",
            sha256: Self.sha256(data),
            byteCount: values.fileSize ?? data.count
        )
    }

    func restore(_ artifact: RecoveryArtifact) throws -> Data {
        let parts = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              UUID(uuidString: String(parts[0])) != nil,
              !parts[1].isEmpty,
              parts[1] != ".", parts[1] != ".." else {
            throw MigrationLedgerError.unsafeRecoveryName
        }
        let url = rootURL
            .appending(path: String(parts[0]), directoryHint: .isDirectory)
            .appending(path: String(parts[1]), directoryHint: .notDirectory)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == artifact.byteCount else {
            throw MigrationLedgerError.recoveryIntegrityFailed
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Self.sha256(data) == artifact.sha256 else {
            throw MigrationLedgerError.recoveryIntegrityFailed
        }
        return data
    }

    private func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MigrationLedgerError.unsafeLedgerPath
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct MigrationLedger {
    let fileURL: URL

    func load() throws -> [MigrationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MigrationLedgerError.unsafeLedgerPath
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self),
               let date = ISO8601DateFormatter().date(from: value) {
                return date
            }
            if let value = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: value)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 string or legacy reference-date number."
            )
        }
        return try decoder.decode([MigrationRecord].self, from: Data(contentsOf: fileURL))
    }

    func save(_ records: [MigrationRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw MigrationLedgerError.unsafeLedgerPath }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MigrationLedgerError.unsafeLedgerPath
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func interruptedRecords() throws -> [MigrationRecord] {
        try load().filter { $0.state.needsRecoveryAfterInterruption }
    }
}
