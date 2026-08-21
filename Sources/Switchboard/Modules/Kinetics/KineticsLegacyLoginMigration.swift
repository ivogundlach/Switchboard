import Foundation
import ServiceManagement
import Darwin

enum KineticsLegacyLoginStatus: String, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

protocol KineticsLegacyLoginService {
    var status: KineticsLegacyLoginStatus { get }
    func unregister() throws
}

struct SystemKineticsLegacyLoginService: KineticsLegacyLoginService {
    private let service: SMAppService

    init(identifier: String = KineticsLegacyLoginMigration.helperBundleIdentifier) {
        service = SMAppService.loginItem(identifier: identifier)
    }

    var status: KineticsLegacyLoginStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func unregister() throws { try service.unregister() }
}

enum KineticsLegacyLoginIntentState: String, Codable, Equatable {
    case planned
    case unregistering
    case unregistered
    case completed
}

struct KineticsLegacyLoginIntent: Codable, Equatable {
    let schemaVersion: Int
    let moduleID: String
    let helperBundleIdentifier: String
    let transactionID: UUID
    var state: KineticsLegacyLoginIntentState

    init(
        moduleID: String = KineticsLegacyLoginMigration.moduleID,
        helperBundleIdentifier: String = KineticsLegacyLoginMigration.helperBundleIdentifier,
        transactionID: UUID = UUID(),
        state: KineticsLegacyLoginIntentState = .planned
    ) {
        schemaVersion = 1
        self.moduleID = moduleID
        self.helperBundleIdentifier = helperBundleIdentifier
        self.transactionID = transactionID
        self.state = state
    }

    func validate() throws {
        guard schemaVersion == 1,
              moduleID == KineticsLegacyLoginMigration.moduleID,
              helperBundleIdentifier == KineticsLegacyLoginMigration.helperBundleIdentifier else {
            throw KineticsLegacyLoginMigrationError.invalidIntent
        }
    }
}

final class KineticsLegacyLoginIntentStore {
    static let fileName = "kinetics-legacy-login-migration.json"

    private let fileManager: FileManager
    let fileURL: URL

    init(
        applicationSupportURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "Switchboard", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        fileURL = applicationSupportURL.appending(path: Self.fileName)
    }

    func load() throws -> KineticsLegacyLoginIntent? {
        guard let attributes = try safeAttributes(at: fileURL) else { return nil }
        guard attributes.type == .typeRegular else { throw KineticsLegacyLoginMigrationError.unsafeIntentFile }
        try validatePermissions(attributes.permissions)
        let intent = try JSONDecoder().decode(KineticsLegacyLoginIntent.self, from: Data(contentsOf: fileURL))
        try intent.validate()
        return intent
    }

    func persist(_ intent: KineticsLegacyLoginIntent) throws {
        try intent.validate()
        let directory = fileURL.deletingLastPathComponent()
        try ensureSafeDirectory(directory)

        let data = try JSONEncoder().encode(intent)
        let temporaryURL = directory.appending(path: ".\(Self.fileName).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporaryURL.path)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if try safeAttributes(at: fileURL) != nil {
            guard try safeAttributes(at: fileURL)?.type == .typeRegular else {
                throw KineticsLegacyLoginMigrationError.unsafeIntentFile
            }
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        try validatePermissions(try safeAttributes(at: fileURL)?.permissions ?? 0)
    }

    private func ensureSafeDirectory(_ directory: URL) throws {
        var current = directory
        var missing: [URL] = []
        while try safeAttributes(at: current) == nil {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { throw KineticsLegacyLoginMigrationError.unsafeIntentPath }
            current = parent
        }
        guard let attributes = try safeAttributes(at: current), attributes.type == .typeDirectory else {
            throw KineticsLegacyLoginMigrationError.unsafeIntentPath
        }
        for directoryURL in missing.reversed() {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directoryURL.path)
        }
        guard let targetAttributes = try safeAttributes(at: directory), targetAttributes.type == .typeDirectory else {
            throw KineticsLegacyLoginMigrationError.unsafeIntentPath
        }
        try validatePermissions(targetAttributes.permissions)
        var check = directory
        while check.path.count >= current.path.count {
            guard let attributes = try safeAttributes(at: check), attributes.type == .typeDirectory else {
                throw KineticsLegacyLoginMigrationError.unsafeIntentPath
            }
            if check.path == current.path { break }
            try validatePermissions(attributes.permissions)
            check = check.deletingLastPathComponent()
        }
    }

    private struct Attributes {
        let type: FileAttributeType
        let permissions: UInt16
        let ownerID: uid_t
    }

    private func safeAttributes(at url: URL) throws -> Attributes? {
        let values: [FileAttributeKey: Any]
        do {
            values = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard let type = values[.type] as? FileAttributeType,
              type != .typeSymbolicLink else {
            throw KineticsLegacyLoginMigrationError.unsafeIntentPath
        }
        let permissions = (values[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let ownerID = (values[.ownerAccountID] as? NSNumber)?.uint32Value ?? UInt32.max
        guard ownerID == getuid() else { throw KineticsLegacyLoginMigrationError.foreignOwner }
        return Attributes(type: type, permissions: permissions, ownerID: ownerID)
    }

    private func validatePermissions(_ permissions: UInt16) throws {
        guard permissions & 0o077 == 0 else {
            throw KineticsLegacyLoginMigrationError.worldReadableIntent
        }
    }
}

enum KineticsLegacyLoginMigrationError: LocalizedError, Equatable {
    case invalidIntent
    case unsafeIntentPath
    case unsafeIntentFile
    case worldReadableIntent
    case foreignOwner
    case unregisterFailed(String)
    case companionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidIntent: "The Kinetics legacy-login intent is malformed."
        case .unsafeIntentPath: "The Kinetics legacy-login intent path is unsafe."
        case .unsafeIntentFile: "The Kinetics legacy-login intent file is not a regular file."
        case .worldReadableIntent: "The Kinetics legacy-login intent is not owner-only."
        case .foreignOwner: "The Kinetics legacy-login intent path has the wrong owner."
        case .unregisterFailed(let detail): "The Kinetics legacy login item could not be unregistered: \(detail)"
        case .companionUnavailable(let detail): "The Kinetics companion is not ready: \(detail)"
        }
    }
}

final class KineticsLegacyLoginMigration {
    static let moduleID = "desktop.kinetics"
    static let helperBundleIdentifier = "com.ivogundlach.Kinetics.LoginLauncher"

    private let service: KineticsLegacyLoginService
    private let intentStore: KineticsLegacyLoginIntentStore

    init(
        service: KineticsLegacyLoginService = SystemKineticsLegacyLoginService(),
        intentStore: KineticsLegacyLoginIntentStore = KineticsLegacyLoginIntentStore()
    ) {
        self.service = service
        self.intentStore = intentStore
    }

    var legacyStatus: KineticsLegacyLoginStatus { service.status }

    func enable(
        currentSelection: Set<String>,
        registerSharedAgent: () throws -> Void,
        validateCompanion: () throws -> Void,
        persistSelection: (Set<String>) throws -> Void
    ) throws {
        guard !currentSelection.contains(Self.moduleID) else { throw KineticsLegacyLoginMigrationError.invalidIntent }
        try validateCompanion()
        var intent = KineticsLegacyLoginIntent(state: .planned)
        try intentStore.persist(intent)
        try registerSharedAgent()
        intent.state = .unregistering
        try intentStore.persist(intent)
        try unregisterAndFinish(
            intent: intent,
            currentSelection: currentSelection,
            validateCompanion: validateCompanion,
            persistSelection: persistSelection
        )
    }

    func retireLegacyLoginAfterHealthyReplacement(
        currentSelection: Set<String>,
        validateCompanion: () throws -> Void
    ) throws {
        guard currentSelection.contains(Self.moduleID) else {
            throw KineticsLegacyLoginMigrationError.invalidIntent
        }
        try validateCompanion()
        var intent = KineticsLegacyLoginIntent(state: .planned)
        try intentStore.persist(intent)
        intent.state = .unregistering
        try intentStore.persist(intent)
        let status = service.status
        if status == .enabled || status == .requiresApproval {
            do { try service.unregister() }
            catch { throw KineticsLegacyLoginMigrationError.unregisterFailed(error.localizedDescription) }
        }
        guard service.status == .notRegistered || service.status == .notFound else {
            throw KineticsLegacyLoginMigrationError.unregisterFailed("the service remains registered")
        }
        intent.state = .unregistered
        try intentStore.persist(intent)
        try validateCompanion()
        intent.state = .completed
        try intentStore.persist(intent)
    }

    @discardableResult
    func resume(
        currentSelection: Set<String>,
        registerSharedAgent: () throws -> Void,
        validateCompanion: () throws -> Void,
        persistSelection: (Set<String>) throws -> Void
    ) throws -> Bool {
        guard let intent = try intentStore.load() else { return false }
        guard intent.state != .completed else { return false }
        try validateCompanion()
        try registerSharedAgent()
        if intent.state == .unregistered {
            try finishSelection(intent: intent, currentSelection: currentSelection, persistSelection: persistSelection)
            return true
        }

        var unregistering = intent
        unregistering.state = .unregistering
        try intentStore.persist(unregistering)
        try unregisterAndFinish(
            intent: unregistering,
            currentSelection: currentSelection,
            validateCompanion: validateCompanion,
            persistSelection: persistSelection
        )
        return true
    }

    private func unregisterAndFinish(
        intent: KineticsLegacyLoginIntent,
        currentSelection: Set<String>,
        validateCompanion: () throws -> Void,
        persistSelection: (Set<String>) throws -> Void
    ) throws {
        let status = service.status
        if status == .enabled || status == .requiresApproval {
            do { try service.unregister() }
            catch { throw KineticsLegacyLoginMigrationError.unregisterFailed(error.localizedDescription) }
        }
        guard service.status == .notRegistered || service.status == .notFound else {
            throw KineticsLegacyLoginMigrationError.unregisterFailed("the service remains registered")
        }
        var unregistered = intent
        unregistered.state = .unregistered
        try intentStore.persist(unregistered)
        try validateCompanion()
        try finishSelection(intent: unregistered, currentSelection: currentSelection, persistSelection: persistSelection)
    }

    private func finishSelection(
        intent: KineticsLegacyLoginIntent,
        currentSelection: Set<String>,
        persistSelection: (Set<String>) throws -> Void
    ) throws {
        var selection = currentSelection
        selection.insert(Self.moduleID)
        try persistSelection(selection)
        var completed = intent
        completed.state = .completed
        try intentStore.persist(completed)
    }
}
