import CryptoKit
import Darwin
import Foundation
import ServiceManagement

enum WarmCornersLiveMigrationPhase: String, Codable {
    case prepared
    case handoffCommitted
    case settingsImported
    case replacementHealthy
    case retirementIntent
    case retired
    case rollingBack
    case rolledBack
    case failed
}

struct WarmCornersBridgeStatus: Codable, Equatable {
    let bridgeVersion: Int
    let capability: String
    let login: String
    let migrationLockPresent: Bool
    let settingsSHA256: String?
    let watcherProcessCount: Int
}

struct WarmCornersLiveMigrationJournal: Codable {
    let schemaVersion: Int
    let transactionID: UUID
    var phase: WarmCornersLiveMigrationPhase
    let priorSwitchboardSettingsPresent: Bool
    let priorSwitchboardSettingsBase64: String?
    let priorEnabledModuleIDs: [String]
    let priorSelectionFilePresent: Bool
    let priorSelectionFileBase64: String?
    let priorMigrationMarker: String?
    let priorSwitchboardLogin: String
    let priorWarmLogin: String
    let priorWarmWasRunning: Bool
    let warmSettingsSHA256: String
    var retirementArchiveSHA256: String?
    var trashPath: String?
    var lastError: String?
}

enum WarmCornersLiveMigrationError: LocalizedError {
    case canonicalInstallRequired
    case legacyBridgeInvalid(String)
    case bridgeCommandFailed(String)
    case bridgeStatusInvalid(String)
    case switchboardLoginRequiresApproval
    case settingsInvalid
    case settingsVerificationFailed
    case recoveryFailed(String)
    case replacementUnhealthy
    case retirementFailed(String)

    var errorDescription: String? {
        switch self {
        case .canonicalInstallRequired: "Switchboard must be installed in Applications before migration."
        case .legacyBridgeInvalid(let detail): "Warm Corners bridge validation failed: \(detail)"
        case .bridgeCommandFailed(let detail): "Warm Corners bridge command failed: \(detail)"
        case .bridgeStatusInvalid(let detail): "Warm Corners bridge status is unsafe: \(detail)"
        case .switchboardLoginRequiresApproval: "Switchboard requires approval in Login Items before Warm Corners can be retired."
        case .settingsInvalid: "Warm Corners settings could not be decoded."
        case .settingsVerificationFailed: "Migrated Warm Corners settings did not verify."
        case .recoveryFailed(let detail): "Warm Corners rollback failed: \(detail)"
        case .replacementUnhealthy: "Switchboard did not start the Warm Corners watcher."
        case .retirementFailed(let detail): "Warm Corners retirement failed: \(detail)"
        }
    }
}

enum WarmCornersLiveMigration {
    static let legacyAppURL = URL(fileURLWithPath: "/Applications/Warm Corners.app", isDirectory: true)
    static let legacyExecutableURL = legacyAppURL.appending(path: "Contents/MacOS/WarmCorners")
    static let switchboardSettingsKey = "switchboard.warm-corners.config"
    static let enabledModulesKey = "switchboard.enabledModuleIDs"
    static let legacySettingsKey = "warmcorners.config"
    static let moduleID = "desktop.warm-corners"
    static let migrationMarkerKey = "switchboard.warm-corners.liveMigrationID"
    static let expectedLegacyRequirementLeaf = "12f05e96dc78def756913a2d574ff98f6c5bd485"

    @MainActor private static var migrationLockFD: Int32 = -1

    static var supportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Switchboard", directoryHint: .isDirectory)
    }

    static func transactionDirectory(_ id: UUID) -> URL {
        supportURL.appending(path: "Recovery/WarmCornersLive/\(id.uuidString)", directoryHint: .isDirectory)
    }

    static func journalURL(_ id: UUID) -> URL {
        transactionDirectory(id).appending(path: "journal.json")
    }

    static func bridgeRecordURL(_ id: UUID) -> URL {
        supportURL.appending(path: "Recovery/WarmCornersBridge/\(id.uuidString)/bridge.json")
    }

    @MainActor
    static func prepare() throws -> UUID {
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Switchboard.app" else {
            throw WarmCornersLiveMigrationError.canonicalInstallRequired
        }
        try validateLegacyBridge()
        let before = try bridgeStatus()
        let warmHash = try validatePreflightStatus(before)

        let defaults = UserDefaults.standard
        let priorSettings = defaults.data(forKey: switchboardSettingsKey)
        let priorEnabled = defaults.stringArray(forKey: enabledModulesKey) ?? []
        let selectionURL = supportURL.appending(path: "enabled-modules.json")
        let priorSelectionPresent = FileManager.default.fileExists(atPath: selectionURL.path)
        let priorSelection = priorSelectionPresent ? try Data(contentsOf: selectionURL) : nil
        let priorSwitchboardLogin = switchboardLoginStatus()
        guard ["enabled", "notRegistered", "notFound"].contains(priorSwitchboardLogin) else {
            throw WarmCornersLiveMigrationError.recoveryFailed("Switchboard login status \(priorSwitchboardLogin) cannot be restored automatically")
        }
        try acquireMigrationLock()

        let id = UUID()
        var journal = WarmCornersLiveMigrationJournal(
            schemaVersion: 1,
            transactionID: id,
            phase: .prepared,
            priorSwitchboardSettingsPresent: priorSettings != nil,
            priorSwitchboardSettingsBase64: priorSettings?.base64EncodedString(),
            priorEnabledModuleIDs: priorEnabled,
            priorSelectionFilePresent: priorSelectionPresent,
            priorSelectionFileBase64: priorSelection?.base64EncodedString(),
            priorMigrationMarker: defaults.string(forKey: migrationMarkerKey),
            priorSwitchboardLogin: priorSwitchboardLogin,
            priorWarmLogin: before.login,
            priorWarmWasRunning: before.watcherProcessCount == 1,
            warmSettingsSHA256: warmHash,
            retirementArchiveSHA256: nil,
            trashPath: nil,
            lastError: nil
        )
        try persist(&journal)

        var handoffAttempted = false
        do {
            if before.login == "enabled", SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            guard before.login != "enabled" || SMAppService.mainApp.status == .enabled else {
                throw WarmCornersLiveMigrationError.switchboardLoginRequiresApproval
            }
            handoffAttempted = true
            try runBridge(["--switchboard-handoff", bridgeRecordURL(id).path, id.uuidString])
            let stopped = try bridgeStatus()
            try validateStoppedStatus(stopped, expectedHash: warmHash)
            journal.phase = .handoffCommitted
            try persist(&journal)

            guard let legacyDefaults = UserDefaults(suiteName: "com.ivogundlach.WarmCorners"),
                  let authoritative = legacyDefaults.data(forKey: legacySettingsKey),
                  sha256(authoritative) == warmHash,
                  let payload = WarmCornerSettingsCodec.decode(authoritative) else {
                throw WarmCornersLiveMigrationError.settingsInvalid
            }
            legacyDefaults.synchronize()
            guard legacyDefaults.data(forKey: legacySettingsKey) == authoritative else {
                throw WarmCornersLiveMigrationError.settingsVerificationFailed
            }

            defaults.set(authoritative, forKey: switchboardSettingsKey)
            var enabled = Set(priorEnabled)
            enabled.insert(moduleID)
            defaults.set(enabled.sorted(), forKey: enabledModulesKey)
            defaults.set(id.uuidString, forKey: migrationMarkerKey)
            try ModuleSelectionFile.save(enabled, to: supportURL)
            defaults.synchronize()
            guard defaults.data(forKey: switchboardSettingsKey).flatMap(WarmCornerSettingsCodec.decode) == payload,
                  Set(defaults.stringArray(forKey: enabledModulesKey) ?? []).contains(moduleID),
                  try ModuleSelectionFile.load(from: supportURL).contains(moduleID) else {
                throw WarmCornersLiveMigrationError.settingsVerificationFailed
            }
            journal.phase = .settingsImported
            try persist(&journal)
            return id
        } catch {
            if handoffAttempted {
                do {
                    journal.phase = .rollingBack
                    journal.lastError = error.localizedDescription
                    try persist(&journal)
                    try restorePriorSwitchboardState(journal)
                    let status = try bridgeStatus()
                    let bridgeMayHaveChanged = status.migrationLockPresent || FileManager.default.fileExists(atPath: bridgeRecordURL(id).path)
                    if bridgeMayHaveChanged {
                        try runBridge(["--switchboard-handoff", bridgeRecordURL(id).path, id.uuidString])
                        try runBridge(["--switchboard-restore", bridgeRecordURL(id).path, id.uuidString])
                        try verifyLegacyRestored(journal)
                    }
                    try restoreSwitchboardLogin(journal.priorSwitchboardLogin)
                    journal.phase = .rolledBack
                    try persist(&journal)
                } catch let rollbackError {
                    journal.phase = .failed
                    journal.lastError = "\(error.localizedDescription); rollback: \(rollbackError.localizedDescription)"
                    try? persist(&journal)
                    releaseMigrationLock()
                    throw WarmCornersLiveMigrationError.recoveryFailed(journal.lastError ?? rollbackError.localizedDescription)
                }
            } else {
                do {
                    try restoreSwitchboardLogin(journal.priorSwitchboardLogin)
                } catch let loginError {
                    releaseMigrationLock()
                    throw WarmCornersLiveMigrationError.recoveryFailed("\(error.localizedDescription); login rollback: \(loginError.localizedDescription)")
                }
            }
            releaseMigrationLock()
            throw error
        }
    }

    @MainActor
    static func reconcileBeforeLaunch() throws -> UUID? {
        let root = supportURL.appending(path: "Recovery/WarmCornersLive", directoryHint: .isDirectory)
        try acquireMigrationLock()
        let transactionIDs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
        var journals: [WarmCornersLiveMigrationJournal] = []
        for id in transactionIDs {
            do {
                let journal = try loadJournal(id)
                if ![.retired, .rolledBack].contains(journal.phase) { journals.append(journal) }
            } catch {
                throw WarmCornersLiveMigrationError.recoveryFailed("transaction \(id.uuidString) has an unreadable journal")
            }
        }
        guard journals.count <= 1 else {
            throw WarmCornersLiveMigrationError.recoveryFailed("multiple incomplete Warm Corners transactions")
        }
        guard let journal = journals.first else {
            releaseMigrationLock()
            return nil
        }
        switch journal.phase {
        case .settingsImported, .replacementHealthy, .retirementIntent:
            return journal.transactionID
        case .prepared, .handoffCommitted, .rollingBack, .failed:
            try rollback(journal.transactionID)
            return nil
        case .retired, .rolledBack:
            return nil
        }
    }

    @MainActor
    static func rollback(_ id: UUID) throws {
        var journal = try loadJournal(id)
        journal.phase = .rollingBack
        try persist(&journal)
        try restorePriorSwitchboardState(journal)
        let status = try bridgeStatus()
        if status.migrationLockPresent || FileManager.default.fileExists(atPath: bridgeRecordURL(id).path) {
            try runBridge(["--switchboard-restore", bridgeRecordURL(id).path, id.uuidString])
            try verifyLegacyRestored(journal)
        }
        try restoreSwitchboardLogin(journal.priorSwitchboardLogin)
        journal.phase = .rolledBack
        journal.lastError = nil
        try persist(&journal)
        releaseMigrationLock()
    }

    @MainActor
    static func finalize(_ id: UUID, warmRuntimeRunning: Bool) throws {
        guard warmRuntimeRunning else { throw WarmCornersLiveMigrationError.replacementUnhealthy }
        var journal = try loadJournal(id)
        guard journal.phase == .settingsImported || journal.phase == .replacementHealthy || journal.phase == .retirementIntent else {
            throw WarmCornersLiveMigrationError.retirementFailed("unexpected phase \(journal.phase.rawValue)")
        }
        let archive = transactionDirectory(id).appending(path: "Warm-Corners-bridge.zip")
        if journal.phase == .retirementIntent,
           !FileManager.default.fileExists(atPath: legacyAppURL.path),
           let expectedHash = journal.retirementArchiveSHA256,
           FileManager.default.fileExists(atPath: archive.path),
           try sha256(file: archive) == expectedHash {
            journal.phase = .retired
            try persist(&journal)
            releaseMigrationLock()
            return
        }
        journal.phase = .replacementHealthy
        try persist(&journal)

        if !FileManager.default.fileExists(atPath: archive.path) {
            let result = try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", legacyAppURL.path, archive.path])
            guard result.status == 0 else {
                throw WarmCornersLiveMigrationError.retirementFailed("archive creation failed: \(result.stderr)")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        }
        journal.retirementArchiveSHA256 = try sha256(file: archive)
        try persist(&journal)
        try validateLegacyBridge()
        let verificationRoot = transactionDirectory(id).appending(path: "archive-verification-\(UUID().uuidString)", directoryHint: .isDirectory)
        try ensurePrivateDirectory(verificationRoot)
        let extraction = try run("/usr/bin/ditto", ["-x", "-k", archive.path, verificationRoot.path])
        guard extraction.status == 0 else {
            throw WarmCornersLiveMigrationError.retirementFailed("archive extraction failed: \(extraction.stderr)")
        }
        try validateLegacyBundle(verificationRoot.appending(path: "Warm Corners.app", directoryHint: .isDirectory))
        journal.phase = .retirementIntent
        try persist(&journal)

        var trashURL: NSURL?
        do {
            try FileManager.default.trashItem(at: legacyAppURL, resultingItemURL: &trashURL)
        } catch {
            throw WarmCornersLiveMigrationError.retirementFailed(error.localizedDescription)
        }
        guard !FileManager.default.fileExists(atPath: legacyAppURL.path), let trashURL else {
            throw WarmCornersLiveMigrationError.retirementFailed("Trash move did not remove the canonical app")
        }
        journal.trashPath = (trashURL as URL).path
        journal.phase = .retired
        try persist(&journal)
        releaseMigrationLock()
    }

    static func runtimeHealthURL(_ id: UUID) -> URL {
        transactionDirectory(id).appending(path: "runtime-health.json")
    }

    static func validatePreflightStatus(_ status: WarmCornersBridgeStatus) throws -> String {
        guard status.bridgeVersion == 1,
              status.capability == "switchboard-headless-migration-v1",
              status.login != "requiresApproval",
              status.migrationLockPresent == false,
              (0...1).contains(status.watcherProcessCount),
              let hash = status.settingsSHA256,
              hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw WarmCornersLiveMigrationError.bridgeStatusInvalid("preflight contract failed")
        }
        return hash
    }

    static func validateStoppedStatus(_ status: WarmCornersBridgeStatus, expectedHash: String) throws {
        guard status.bridgeVersion == 1,
              status.capability == "switchboard-headless-migration-v1",
              status.migrationLockPresent,
              status.watcherProcessCount == 0,
              status.login == "notRegistered" || status.login == "notFound",
              status.settingsSHA256 == expectedHash else {
            throw WarmCornersLiveMigrationError.bridgeStatusInvalid("handoff did not quiesce the legacy app")
        }
    }

    static var completedTransactionID: UUID? {
        guard let value = UserDefaults.standard.string(forKey: migrationMarkerKey) else { return nil }
        return UUID(uuidString: value)
    }

    private static func switchboardLoginStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    private static func restoreSwitchboardLogin(_ prior: String) throws {
        switch prior {
        case "enabled":
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            guard SMAppService.mainApp.status == .enabled else {
                throw WarmCornersLiveMigrationError.recoveryFailed("Switchboard login item was not restored to enabled")
            }
        case "notRegistered", "notFound":
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        default:
            throw WarmCornersLiveMigrationError.recoveryFailed("unsupported prior Switchboard login status \(prior)")
        }
    }

    static func writeRuntimeHealth(_ id: UUID, warmRunning: Bool) throws {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "transactionID": id.uuidString,
            "pid": getpid(),
            "warmRuntimeRunning": warmRunning,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try ensurePrivateDirectory(transactionDirectory(id))
        try data.write(to: runtimeHealthURL(id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeHealthURL(id).path)
    }

    static func writeCurrentRuntimeHealth(warmRunning: Bool) throws {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "pid": getpid(),
            "warmRuntimeRunning": warmRunning,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try ensurePrivateDirectory(supportURL)
        let url = supportURL.appending(path: "runtime-health.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func validateLegacyBridge() throws {
        try validateLegacyBundle(legacyAppURL)
    }

    private static func validateLegacyBundle(_ bundleURL: URL) throws {
        let executableURL = bundleURL.appending(path: "Contents/MacOS/WarmCorners")
        let values = try bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              Bundle(url: bundleURL)?.bundleIdentifier == "com.ivogundlach.WarmCorners",
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WarmCornersLiveMigrationError.legacyBridgeInvalid("canonical bundle identity")
        }
        let exactRequirement = "=identifier \"com.ivogundlach.WarmCorners\" and certificate leaf = H\"\(expectedLegacyRequirementLeaf)\""
        let verified = try run("/usr/bin/codesign", [
            "--verify", "--deep", "--strict", "--verbose=2", "-R", exactRequirement, bundleURL.path,
        ])
        guard verified.status == 0 else {
            throw WarmCornersLiveMigrationError.legacyBridgeInvalid(verified.stderr)
        }
    }

    private static func bridgeStatus() throws -> WarmCornersBridgeStatus {
        let result = try run(legacyExecutableURL.path, ["--switchboard-status"])
        guard result.status == 0, result.stderr.isEmpty,
              let data = result.stdout.data(using: .utf8), data.count <= 65_536,
              let status = try? JSONDecoder().decode(WarmCornersBridgeStatus.self, from: data) else {
            throw WarmCornersLiveMigrationError.bridgeStatusInvalid(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return status
    }

    private static func runBridge(_ arguments: [String]) throws {
        try validateLegacyBridge()
        let result = try run(legacyExecutableURL.path, arguments)
        guard result.status == 0 else {
            throw WarmCornersLiveMigrationError.bridgeCommandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        try validateLegacyBridge()
    }

    private static func restorePriorSwitchboardState(_ journal: WarmCornersLiveMigrationJournal) throws {
        let defaults = UserDefaults.standard
        if journal.priorSwitchboardSettingsPresent,
           let encoded = journal.priorSwitchboardSettingsBase64,
           let data = Data(base64Encoded: encoded) {
            defaults.set(data, forKey: switchboardSettingsKey)
        } else {
            defaults.removeObject(forKey: switchboardSettingsKey)
        }
        defaults.set(journal.priorEnabledModuleIDs, forKey: enabledModulesKey)
        if let priorMarker = journal.priorMigrationMarker {
            defaults.set(priorMarker, forKey: migrationMarkerKey)
        } else {
            defaults.removeObject(forKey: migrationMarkerKey)
        }
        let selectionURL = supportURL.appending(path: "enabled-modules.json")
        if journal.priorSelectionFilePresent,
           let encoded = journal.priorSelectionFileBase64,
           let data = Data(base64Encoded: encoded) {
            try data.write(to: selectionURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: selectionURL.path)
        } else if !journal.priorSelectionFilePresent, FileManager.default.fileExists(atPath: selectionURL.path) {
            try FileManager.default.removeItem(at: selectionURL)
        } else if journal.priorSelectionFilePresent {
            throw WarmCornersLiveMigrationError.recoveryFailed("prior module selection snapshot is missing")
        }
        defaults.synchronize()
    }

    private static func verifyLegacyRestored(_ journal: WarmCornersLiveMigrationJournal) throws {
        let status = try bridgeStatus()
        guard !status.migrationLockPresent,
              status.settingsSHA256 == journal.warmSettingsSHA256,
              status.login == journal.priorWarmLogin,
              status.watcherProcessCount == (journal.priorWarmWasRunning ? 1 : 0) else {
            throw WarmCornersLiveMigrationError.recoveryFailed("legacy state did not match the preflight snapshot")
        }
    }

    private static func persist(_ journal: inout WarmCornersLiveMigrationJournal) throws {
        let directory = transactionDirectory(journal.transactionID)
        try ensurePrivateDirectory(directory)
        let data = try JSONEncoder().encode(journal)
        let url = journalURL(journal.transactionID)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func loadJournal(_ id: UUID) throws -> WarmCornersLiveMigrationJournal {
        try JSONDecoder().decode(WarmCornersLiveMigrationJournal.self, from: Data(contentsOf: journalURL(id)))
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    @MainActor
    private static func acquireMigrationLock() throws {
        if migrationLockFD >= 0 { return }
        let root = supportURL.appending(path: "Recovery/WarmCornersLive", directoryHint: .isDirectory)
        try ensurePrivateDirectory(root)
        let lockURL = root.appending(path: "migration.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw WarmCornersLiveMigrationError.recoveryFailed("migration lock could not be opened")
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw WarmCornersLiveMigrationError.recoveryFailed("another Warm Corners migration is active")
        }
        migrationLockFD = fd
    }

    @MainActor
    private static func releaseMigrationLock() {
        guard migrationLockFD >= 0 else { return }
        _ = flock(migrationLockFD, LOCK_UN)
        close(migrationLockFD)
        migrationLockFD = -1
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(file url: URL) throws -> String {
        try sha256(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let temporary = FileManager.default.temporaryDirectory
        let stdoutURL = temporary.appending(path: "switchboard-migration-\(UUID().uuidString).stdout")
        let stderrURL = temporary.appending(path: "switchboard-migration-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outputLimit: UInt64 = 1_048_576
        var outputOverflow = false
        while process.isRunning {
            let outSize = (try? stdoutURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            let errSize = (try? stderrURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            if outSize + errSize > outputLimit {
                outputOverflow = true
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        let outSize = try stdoutURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let errSize = try stderrURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard !outputOverflow, outSize >= 0, errSize >= 0, UInt64(outSize + errSize) <= outputLimit else {
            throw WarmCornersLiveMigrationError.bridgeCommandFailed("subprocess output exceeded 1 MiB")
        }
        let outReader = try FileHandle(forReadingFrom: stdoutURL)
        let errReader = try FileHandle(forReadingFrom: stderrURL)
        defer { try? outReader.close(); try? errReader.close() }
        let outData = try outReader.read(upToCount: Int(outputLimit) + 1) ?? Data()
        let errData = try errReader.read(upToCount: Int(outputLimit) + 1) ?? Data()
        guard outData.count + errData.count <= Int(outputLimit) else {
            throw WarmCornersLiveMigrationError.bridgeCommandFailed("subprocess output exceeded 1 MiB")
        }
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
