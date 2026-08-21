import CryptoKit
import Foundation

struct LegacySchedulerCommandResult: Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var succeeded: Bool { status == 0 }
}

protocol LegacySchedulerCommandRunning {
    func run(executable: String, arguments: [String], input: Data?) throws -> LegacySchedulerCommandResult
}

struct LegacySchedulerFileMetadata: Equatable {
    let exists: Bool
    let isSymbolicLink: Bool
    let isRegularFile: Bool
}

protocol LegacySchedulerFileSystem {
    func metadata(at url: URL) throws -> LegacySchedulerFileMetadata
    func read(_ url: URL) throws -> Data
    func write(_ data: Data, to url: URL, permissions: UInt16) throws
    func createDirectory(_ url: URL, permissions: UInt16) throws
    func move(_ source: URL, to destination: URL) throws
}

protocol LegacySchedulerStatePersisting {
    func persist(_ record: LegacySchedulerMigrationRecord) throws
}

struct LegacySchedulerMigrationEnvironment {
    let homeDirectory: URL
    let applicationSupportDirectory: URL
    let userID: uid_t

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = nil,
        userID: uid_t = getuid()
    ) {
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? homeDirectory.appending(path: "Library/Application Support/Switchboard")
        self.userID = userID
    }
}

enum LegacySchedulerMigrationState: String, Codable, Equatable {
    case planned
    case snapshotting
    case snapshotted
    case quiescing
    case quiesced
    case completed
    case rollingBack
    case rolledBack
    case failed
}

struct LegacySchedulerMigrationEvent: Codable, Equatable {
    let state: LegacySchedulerMigrationState
    let action: String
}

struct LegacySchedulerRecoveryArtifact: Codable, Equatable {
    let label: String
    let kind: String
    let originalPath: String?
    let recoveryPath: String
    let sha256: String
    let byteCount: Int
    let wasLoaded: Bool
}

struct LegacySchedulerMigrationRecord: Codable, Equatable {
    let moduleID: String
    let transactionID: UUID
    var state: LegacySchedulerMigrationState
    var events: [LegacySchedulerMigrationEvent]
    var artifacts: [LegacySchedulerRecoveryArtifact]

    init(moduleID: String, transactionID: UUID = UUID()) {
        self.moduleID = moduleID
        self.transactionID = transactionID
        state = .planned
        events = [.init(state: .planned, action: "intent recorded")]
        artifacts = []
    }
}

enum LegacySchedulerMigrationError: LocalizedError, Equatable {
    case invalidModuleID
    case invalidLabel(String)
    case unsupportedLabel(String)
    case privilegedEnvironment
    case missingLegacyFile(String)
    case commandFailed(String, Int32)
    case verificationFailed(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidModuleID: "The module ID is not a safe path component."
        case .invalidLabel(let label): "The scheduler label is invalid: \(label)."
        case .unsupportedLabel(let label): "The scheduler label is unsupported: \(label)."
        case .privilegedEnvironment: "Privileged or root scheduler paths are not supported."
        case .missingLegacyFile(let label): "The legacy scheduler file is missing: \(label)."
        case .commandFailed(let command, let status): "The command failed (\(command), status \(status))."
        case .verificationFailed(let detail): "Legacy scheduler verification failed: \(detail)."
        case .rollbackFailed(let detail): "Legacy scheduler rollback failed: \(detail)."
        }
    }
}

final class LocalLegacySchedulerFileSystem: LegacySchedulerFileSystem {
    private let fileManager = FileManager.default

    func metadata(at url: URL) throws -> LegacySchedulerFileMetadata {
        let attributes: [FileAttributeKey: Any]
        do {
            // attributesOfItem inspects the directory entry itself, so dangling
            // symlinks are rejected instead of silently treated as missing.
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return LegacySchedulerFileMetadata(exists: false, isSymbolicLink: false, isRegularFile: false)
        } catch {
            throw error
        }
        return LegacySchedulerFileMetadata(
            exists: true,
            isSymbolicLink: (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
            isRegularFile: (attributes[.type] as? FileAttributeType) == .typeRegular
        )
    }

    func read(_ url: URL) throws -> Data { try Data(contentsOf: url, options: [.mappedIfSafe]) }

    func write(_ data: Data, to url: URL, permissions: UInt16) throws {
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    func createDirectory(_ url: URL, permissions: UInt16) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    func move(_ source: URL, to destination: URL) throws { try fileManager.moveItem(at: source, to: destination) }
}

final class LocalLegacySchedulerCommandRunner: LegacySchedulerCommandRunning {
    func run(executable: String, arguments: [String], input: Data?) throws -> LegacySchedulerCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(input)
            pipe.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        return LegacySchedulerCommandResult(
            status: process.terminationStatus,
            stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: error.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

final class FileLegacySchedulerStateStore: LegacySchedulerStatePersisting {
    private let fileSystem: LegacySchedulerFileSystem
    private let fileURL: URL

    init(fileSystem: LegacySchedulerFileSystem = LocalLegacySchedulerFileSystem(), fileURL: URL) {
        self.fileSystem = fileSystem
        self.fileURL = fileURL
    }

    func persist(_ record: LegacySchedulerMigrationRecord) throws {
        let data = try JSONEncoder().encode(record)
        let directory = fileURL.deletingLastPathComponent()
        try fileSystem.createDirectory(directory, permissions: 0o700)
        try fileSystem.write(data, to: fileURL, permissions: 0o600)
    }
}

final class LegacySchedulerMigration {
    static let launchctlPath = "/bin/launchctl"
    static let crontabPath = "/usr/bin/crontab"
    static let cronLabel = "cron:backup-coverage-audit"

    private let moduleID: String
    private let labels: [String]
    private let environment: LegacySchedulerMigrationEnvironment
    private let fileSystem: LegacySchedulerFileSystem
    private let commands: LegacySchedulerCommandRunning
    private let persistence: LegacySchedulerStatePersisting
    private let launchctlVerificationAttempts: Int
    private let launchctlVerificationDelay: () -> Void

    init(
        moduleID: String,
        legacyLabels: [String],
        environment: LegacySchedulerMigrationEnvironment = .init(),
        fileSystem: LegacySchedulerFileSystem = LocalLegacySchedulerFileSystem(),
        commands: LegacySchedulerCommandRunning = LocalLegacySchedulerCommandRunner(),
        persistence: LegacySchedulerStatePersisting? = nil,
        launchctlVerificationAttempts: Int = 51,
        launchctlVerificationDelay: @escaping () -> Void = {
            Thread.sleep(forTimeInterval: 0.1)
        }
    ) {
        self.moduleID = moduleID
        self.labels = legacyLabels
        self.environment = environment
        self.fileSystem = fileSystem
        self.commands = commands
        self.launchctlVerificationAttempts = max(1, launchctlVerificationAttempts)
        self.launchctlVerificationDelay = launchctlVerificationDelay
        self.persistence = persistence ?? FileLegacySchedulerStateStore(
            fileSystem: fileSystem,
            fileURL: environment.applicationSupportDirectory
                .appending(path: "Migration/\(moduleID).json")
        )
    }

    @discardableResult
    func migrate() throws -> LegacySchedulerMigrationRecord {
        guard Self.isSafeComponent(moduleID) else { throw LegacySchedulerMigrationError.invalidModuleID }
        guard environment.userID != 0,
              environment.homeDirectory.standardizedFileURL.path != "/",
              environment.applicationSupportDirectory.standardizedFileURL.path != "/" else {
            throw LegacySchedulerMigrationError.privilegedEnvironment
        }
        guard !labels.isEmpty else { return try finishEmptyMigration() }
        for label in labels {
            guard Self.isValidLabel(label) else { throw LegacySchedulerMigrationError.invalidLabel(label) }
        }
        // Reject symlinked LaunchAgent entries before recording a migration or
        // creating a recovery snapshot. This also catches dangling symlinks.
        for label in labels where label != Self.cronLabel {
            let originalURL = launchAgentURL(for: label)
            let metadata = try fileSystem.metadata(at: originalURL)
            if metadata.isSymbolicLink || (metadata.exists && !metadata.isRegularFile) {
                throw LegacySchedulerMigrationError.verificationFailed("legacy plist is a symbolic link: \(label)")
            }
        }

        var record = LegacySchedulerMigrationRecord(moduleID: moduleID)
        try persistence.persist(record)
        var snapshots: [Snapshot] = []
        do {
            for label in labels {
                if let snapshot = try snapshot(label: label, record: &record) {
                    snapshots.append(snapshot)
                }
            }
            for snapshot in snapshots {
                try quiesce(snapshot, record: &record)
            }
            try transition(&record, to: .completed, action: "migration completed")
            try persistence.persist(record)
            return record
        } catch {
            do {
                try rollback(snapshots, record: &record)
                return try failedRecord(record, original: error)
            } catch let rollbackError {
                throw rollbackError
            }
        }
    }

    @discardableResult
    func restoreLastMigration() throws -> Bool {
        let recordURL = environment.applicationSupportDirectory
            .appending(path: "Migration/\(moduleID).json")
        let metadata = try fileSystem.metadata(at: recordURL)
        guard metadata.exists, metadata.isRegularFile, !metadata.isSymbolicLink else { return false }
        var record = try JSONDecoder().decode(
            LegacySchedulerMigrationRecord.self,
            from: fileSystem.read(recordURL)
        )
        guard record.moduleID == moduleID,
              record.state == .completed || record.state == .quiescing
                || record.state == .quiesced || record.state == .rollingBack else {
            return false
        }
        try transition(&record, to: .rollingBack, action: "replacement health rollback intent")
        try persistence.persist(record)
        for artifact in record.artifacts.reversed() {
            let recoveryURL = URL(fileURLWithPath: artifact.recoveryPath)
            let recovery = try fileSystem.read(recoveryURL)
            guard Self.sha256(recovery) == artifact.sha256, recovery.count == artifact.byteCount else {
                throw LegacySchedulerMigrationError.rollbackFailed("recovery snapshot mismatch: \(artifact.label)")
            }
            if artifact.kind == "cron" {
                guard artifact.wasLoaded else { continue }
                let currentResult = try runCrontab(arguments: ["-l"])
                let current = currentResult.succeeded ? currentResult.stdout : Data()
                let line = Self.backupAuditCronLine(homeDirectory: environment.homeDirectory)
                let matches = Self.countExactCronLines(line, in: current)
                guard matches <= 1 else {
                    throw LegacySchedulerMigrationError.rollbackFailed("ambiguous duplicate cron entries")
                }
                if matches == 0 {
                    var replacement = current
                    if !replacement.isEmpty, replacement.last != 10 { replacement.append(10) }
                    replacement.append(Data((line + "\n").utf8))
                    let result = try runCrontab(arguments: ["-"], input: replacement)
                    guard result.succeeded else {
                        throw LegacySchedulerMigrationError.rollbackFailed("could not restore cron")
                    }
                }
                continue
            }
            guard let originalPath = artifact.originalPath else {
                throw LegacySchedulerMigrationError.rollbackFailed("missing original path: \(artifact.label)")
            }
            let originalURL = URL(fileURLWithPath: originalPath)
            let originalMetadata = try fileSystem.metadata(at: originalURL)
            if !originalMetadata.exists {
                let archived = archiveURL(for: artifact.label, transactionID: record.transactionID)
                if try fileSystem.metadata(at: archived).exists {
                    try fileSystem.move(archived, to: originalURL)
                } else {
                    try fileSystem.write(recovery, to: originalURL, permissions: 0o600)
                }
            }
            if artifact.wasLoaded, try !isLoaded(artifact.label) {
                let result = try runLaunchctl(arguments: ["bootstrap", "gui/\(environment.userID)", originalURL.path])
                guard result.succeeded,
                      try waitForLoadedState(artifact.label, expectedLoaded: true) else {
                    throw LegacySchedulerMigrationError.rollbackFailed("could not reload \(artifact.label)")
                }
            }
        }
        try transition(&record, to: .rolledBack, action: "replacement health rollback completed")
        try persistence.persist(record)
        return true
    }

    func reconcileInterruptedMigration() throws -> Bool {
        let recordURL = environment.applicationSupportDirectory
            .appending(path: "Migration/\(moduleID).json")
        let metadata = try fileSystem.metadata(at: recordURL)
        guard metadata.exists, metadata.isRegularFile, !metadata.isSymbolicLink else { return false }
        let record = try JSONDecoder().decode(
            LegacySchedulerMigrationRecord.self,
            from: fileSystem.read(recordURL)
        )
        guard record.moduleID == moduleID,
              record.state == .quiescing || record.state == .quiesced || record.state == .rollingBack else {
            return false
        }
        return try restoreLastMigration()
    }

    private func finishEmptyMigration() throws -> LegacySchedulerMigrationRecord {
        var record = LegacySchedulerMigrationRecord(moduleID: moduleID)
        try transition(&record, to: .completed, action: "no legacy labels")
        try persistence.persist(record)
        return record
    }

    private struct Snapshot {
        let label: String
        let kind: Kind
        let originalURL: URL?
        let recoveryURL: URL
        let archiveURL: URL
        let originalData: Data
        let wasLoaded: Bool
    }

    private enum Kind { case launchAgent, cron }

    private func snapshot(label: String, record: inout LegacySchedulerMigrationRecord) throws -> Snapshot? {
        if label != Self.cronLabel {
            let originalURL = launchAgentURL(for: label)
            let metadata = try fileSystem.metadata(at: originalURL)
            if metadata.isSymbolicLink || (metadata.exists && !metadata.isRegularFile) {
                throw LegacySchedulerMigrationError.verificationFailed("legacy plist is a symbolic link: \(label)")
            }
        }
        try transition(&record, to: .snapshotting, action: "snapshot intent: \(label)")
        try persistence.persist(record)
        let recoveryURL = recoveryURL(for: label, transactionID: record.transactionID)
        let archiveURL = archiveURL(for: label, transactionID: record.transactionID)
        try fileSystem.createDirectory(recoveryURL.deletingLastPathComponent(), permissions: 0o700)

        switch label == Self.cronLabel {
        case true:
            let listed = try runCrontab(arguments: ["-l"])
            let data = listed.succeeded ? listed.stdout : Data()
            let exactLine = Self.backupAuditCronLine(homeDirectory: environment.homeDirectory)
            let matchCount = Self.countExactCronLines(exactLine, in: data)
            guard matchCount <= 1 else {
                throw LegacySchedulerMigrationError.verificationFailed("ambiguous duplicate cron entries")
            }
            let present = matchCount == 1
            let hash = Self.sha256(data)
            try fileSystem.write(data, to: recoveryURL, permissions: 0o600)
            record.artifacts.append(.init(
                label: label, kind: "cron", originalPath: nil,
                recoveryPath: recoveryURL.path, sha256: hash, byteCount: data.count, wasLoaded: present
            ))
            try transition(&record, to: .snapshotted, action: "snapshot saved: \(label)")
            try persistence.persist(record)
            return Snapshot(label: label, kind: .cron, originalURL: nil, recoveryURL: recoveryURL,
                            archiveURL: recoveryURL, originalData: data, wasLoaded: present)
        case false:
            let originalURL = launchAgentURL(for: label)
            let metadata = try fileSystem.metadata(at: originalURL)
            guard !metadata.isSymbolicLink else {
                throw LegacySchedulerMigrationError.verificationFailed("legacy plist is a symbolic link: \(label)")
            }
            guard metadata.exists else {
                guard try !isLoaded(label) else {
                    throw LegacySchedulerMigrationError.missingLegacyFile(label)
                }
                try transition(&record, to: .snapshotted, action: "not present: \(label)")
                try persistence.persist(record)
                return nil
            }
            guard metadata.isRegularFile else {
                throw LegacySchedulerMigrationError.verificationFailed("legacy plist is not a regular file: \(label)")
            }
            // Re-check immediately before reading in case the directory entry
            // changed after the initial metadata check.
            let recheckedMetadata = try fileSystem.metadata(at: originalURL)
            guard !recheckedMetadata.isSymbolicLink, recheckedMetadata.isRegularFile else {
                throw LegacySchedulerMigrationError.verificationFailed("legacy plist is a symbolic link: \(label)")
            }
            let data = try fileSystem.read(originalURL)
            let loaded = try isLoaded(label)
            let hash = Self.sha256(data)
            try fileSystem.write(data, to: recoveryURL, permissions: 0o600)
            record.artifacts.append(.init(
                label: label, kind: "launchAgent", originalPath: originalURL.path,
                recoveryPath: recoveryURL.path, sha256: hash, byteCount: data.count, wasLoaded: loaded
            ))
            try transition(&record, to: .snapshotted, action: "snapshot saved: \(label)")
            try persistence.persist(record)
            return Snapshot(label: label, kind: .launchAgent, originalURL: originalURL,
                            recoveryURL: recoveryURL, archiveURL: archiveURL, originalData: data, wasLoaded: loaded)
        }
    }

    private func quiesce(_ snapshot: Snapshot, record: inout LegacySchedulerMigrationRecord) throws {
        try transition(&record, to: .quiescing, action: "quiescence intent: \(snapshot.label)")
        try persistence.persist(record)
        switch snapshot.kind {
        case .launchAgent:
            if snapshot.wasLoaded {
                try transition(&record, to: .quiescing, action: "bootout intent: \(snapshot.label)")
                try persistence.persist(record)
                let result = try runLaunchctl(arguments: ["bootout", launchDomain(snapshot.label)])
                guard result.succeeded else {
                    throw LegacySchedulerMigrationError.commandFailed("launchctl bootout", result.status)
                }
            }
            guard try waitForLoadedState(snapshot.label, expectedLoaded: false) else {
                throw LegacySchedulerMigrationError.verificationFailed("loaded launch agent \(snapshot.label)")
            }
            try persistence.persist(record)
            if let originalURL = snapshot.originalURL {
                guard try !fileSystem.metadata(at: originalURL).isSymbolicLink else {
                    throw LegacySchedulerMigrationError.verificationFailed("legacy plist is a symbolic link: \(snapshot.label)")
                }
                try transition(&record, to: .quiesced, action: "move intent: \(snapshot.label)")
                try persistence.persist(record)
                try fileSystem.move(originalURL, to: snapshot.archiveURL)
                guard !(try fileSystem.metadata(at: originalURL).exists) else {
                    throw LegacySchedulerMigrationError.verificationFailed("legacy plist remains: \(snapshot.label)")
                }
                guard try !isLoaded(snapshot.label) else {
                    throw LegacySchedulerMigrationError.verificationFailed("launch agent reappeared: \(snapshot.label)")
                }
            }
        case .cron:
            guard snapshot.wasLoaded else {
                try transition(&record, to: .quiesced, action: "cron line not present: \(snapshot.label)")
                try persistence.persist(record)
                return
            }
            let current = try runCrontab(arguments: ["-l"]).stdout
            let exactLine = Self.backupAuditCronLine(homeDirectory: environment.homeDirectory)
            guard Self.countExactCronLines(exactLine, in: current) == 1 else {
                throw LegacySchedulerMigrationError.verificationFailed("cron changed or contains ambiguous matches")
            }
            let replacement = Self.removingExactCronLine(exactLine, from: current)
            guard replacement != current else {
                throw LegacySchedulerMigrationError.verificationFailed("cron line not found: \(snapshot.label)")
            }
            try transition(&record, to: .quiescing, action: "cron replacement intent: \(snapshot.label)")
            try persistence.persist(record)
            let result = try runCrontab(arguments: ["-"], input: replacement)
            guard result.succeeded else {
                throw LegacySchedulerMigrationError.commandFailed("crontab replacement", result.status)
            }
            guard !Self.containsExactCronLine(exactLine, in: try runCrontab(arguments: ["-l"]).stdout) else {
                throw LegacySchedulerMigrationError.verificationFailed("cron line remains: \(snapshot.label)")
            }
            try transition(&record, to: .quiesced, action: "cron replacement verified: \(snapshot.label)")
            try persistence.persist(record)
        }
    }

    private func rollback(_ snapshots: [Snapshot], record: inout LegacySchedulerMigrationRecord) throws {
        try transition(&record, to: .rollingBack, action: "rollback intent")
        try persistence.persist(record)
        var firstError: Error?
        for snapshot in snapshots.reversed() {
            do {
                switch snapshot.kind {
                case .launchAgent:
                    if let originalURL = snapshot.originalURL {
                        if try fileSystem.metadata(at: snapshot.archiveURL).exists {
                            if try fileSystem.metadata(at: originalURL).exists {
                                throw LegacySchedulerMigrationError.rollbackFailed("destination exists: \(originalURL.path)")
                            }
                            try fileSystem.move(snapshot.archiveURL, to: originalURL)
                        }
                        if snapshot.wasLoaded {
                            let result = try runLaunchctl(arguments: ["bootstrap", "gui/\(environment.userID)", originalURL.path])
                            guard result.succeeded,
                                  try waitForLoadedState(snapshot.label, expectedLoaded: true) else {
                                throw LegacySchedulerMigrationError.rollbackFailed("could not reload \(snapshot.label)")
                            }
                        }
                    }
                case .cron:
                    guard snapshot.wasLoaded else { continue }
                    let result = try runCrontab(arguments: ["-"], input: snapshot.originalData)
                    guard result.succeeded, try runCrontab(arguments: ["-l"]).stdout == snapshot.originalData else {
                        throw LegacySchedulerMigrationError.rollbackFailed("could not restore crontab")
                    }
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        try transition(&record, to: .rolledBack, action: "rollback completed")
        try persistence.persist(record)
    }

    private func failedRecord(_ record: LegacySchedulerMigrationRecord, original: Error) throws -> LegacySchedulerMigrationRecord {
        var record = record
        try transition(&record, to: .failed, action: "migration failed: \(original.localizedDescription)")
        try persistence.persist(record)
        throw original
    }

    private func transition(_ record: inout LegacySchedulerMigrationRecord,
                             to state: LegacySchedulerMigrationState,
                             action: String) throws {
        record.state = state
        record.events.append(.init(state: state, action: action))
    }

    private func launchAgentURL(for label: String) -> URL {
        environment.homeDirectory
            .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(label).plist", directoryHint: .notDirectory)
    }

    private func recoveryURL(for label: String, transactionID: UUID) -> URL {
        environment.applicationSupportDirectory
            .appending(path: "Recovery/LegacySchedulers/\(moduleID)/\(transactionID.uuidString)", directoryHint: .isDirectory)
            .appending(path: "\(label.replacingOccurrences(of: ":", with: "-")).snapshot", directoryHint: .notDirectory)
    }

    private func archiveURL(for label: String, transactionID: UUID) -> URL {
        environment.applicationSupportDirectory
            .appending(path: "Recovery/LegacySchedulers/\(moduleID)/\(transactionID.uuidString)", directoryHint: .isDirectory)
            .appending(path: "\(label.replacingOccurrences(of: ":", with: "-")).plist", directoryHint: .notDirectory)
    }

    private func launchDomain(_ label: String) -> String { "gui/\(environment.userID)/\(label)" }

    private func isLoaded(_ label: String) throws -> Bool {
        try runLaunchctl(arguments: ["print", launchDomain(label)]).succeeded
    }

    private func waitForLoadedState(_ label: String, expectedLoaded: Bool) throws -> Bool {
        for attempt in 0..<launchctlVerificationAttempts {
            if try isLoaded(label) == expectedLoaded { return true }
            if attempt + 1 < launchctlVerificationAttempts {
                launchctlVerificationDelay()
            }
        }
        return false
    }

    private func runLaunchctl(arguments: [String]) throws -> LegacySchedulerCommandResult {
        try commands.run(executable: Self.launchctlPath, arguments: arguments, input: nil)
    }

    private func runCrontab(arguments: [String], input: Data? = nil) throws -> LegacySchedulerCommandResult {
        try commands.run(executable: Self.crontabPath, arguments: arguments, input: input)
    }

    static func isValidLabel(_ label: String) -> Bool {
        if label == cronLabel { return true }
        guard !label.isEmpty, label.utf8.count <= 255 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard label.unicodeScalars.allSatisfy(allowed.contains),
              label.first?.isLetter == true || label.first?.isNumber == true,
              label.last?.isLetter == true || label.last?.isNumber == true else { return false }
        return !label.contains("..") && !label.contains(".-") && !label.contains("-.")
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    static func backupAuditCronLine(homeDirectory: URL) -> String {
        let home = homeDirectory.standardizedFileURL.path
        return "0 4 * * * \(home)/.local/bin/backup-coverage-audit > \(home)/.local/state/backup-coverage-audit/cron.log 2>&1 # backup-coverage-audit"
    }

    static func containsExactCronLine(_ exactLine: String, in data: Data) -> Bool {
        countExactCronLines(exactLine, in: data) > 0
    }

    static func countExactCronLines(_ exactLine: String, in data: Data) -> Int {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).reduce(into: 0) { count, line in
            let line = line.last == 0x0D ? line.dropLast() : line[...]
            if Data(line) == Data(exactLine.utf8) { count += 1 }
        }
    }

    static func removingExactCronLine(_ exactLine: String, from data: Data) -> Data {
        let bytes = [UInt8](data)
        var result = [UInt8]()
        var start = 0
        for index in 0...bytes.count {
            guard index == bytes.count || bytes[index] == 0x0A else { continue }
            let lineEnd = index > start && bytes[index - 1] == 0x0D ? index - 1 : index
            let line = Data(bytes[start..<lineEnd])
            if line != Data(exactLine.utf8) {
                result.append(contentsOf: bytes[start..<index])
                if index < bytes.count { result.append(0x0A) }
            }
            start = index + 1
        }
        return Data(result)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
