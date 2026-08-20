import CryptoKit
import Foundation

protocol BundledServiceActivationFileSystem {
    func metadata(at url: URL) throws -> BundledServiceFileMetadata?
    func readData(at url: URL) throws -> Data
    func createDirectory(at url: URL, permissions: UInt16) throws
    func writeDataAtomically(_ data: Data, to url: URL, permissions: UInt16) throws
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func atomicallyMoveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func treeSnapshot(at url: URL) throws -> [BundledServiceTreeEntry]
}

struct BundledServiceFileMetadata: Codable, Equatable {
    let isRegularFile: Bool
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let posixPermissions: UInt16
    let modificationDate: Date?
}

struct BundledServiceTreeEntry: Codable, Equatable {
    let relativePath: String
    let metadata: BundledServiceFileMetadata
    let data: Data?
}

enum BundledServiceActivationError: Error, Equatable {
    case nonCanonicalBundle(URL)
    case invalidServiceName(String)
    case sourceMissing(URL)
    case sourceIsSymbolicLink(URL)
    case sourceIsNotDirectory(URL)
    case requiredFileMissing(URL)
    case requiredFileIsSymbolicLink(URL)
    case requiredFileIsNotRegular(URL)
    case legacyItemIsSymbolicLink(URL)
    case legacyItemIsNotDirectory(URL)
    case stateCorrupt(URL)
    case rollbackFailed(String)
}

private struct BundledServiceActivationRecord: Codable, Equatable {
    let serviceName: String
    let destinationURL: URL
    let stageURL: URL
    let transactionDirectory: URL
    let legacyBackupURL: URL?
    let installedTreeDigest: String
    let legacyTreeDigest: String?
}

private struct BundledServiceActivationState: Codable, Equatable {
    let schemaVersion: Int
    let serviceName: String
    let record: BundledServiceActivationRecord
    var pendingDisable: Bool

    init(
        schemaVersion: Int,
        serviceName: String,
        record: BundledServiceActivationRecord,
        pendingDisable: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.serviceName = serviceName
        self.record = record
        self.pendingDisable = pendingDisable
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, serviceName, record, pendingDisable
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        serviceName = try values.decode(String.self, forKey: .serviceName)
        record = try values.decode(BundledServiceActivationRecord.self, forKey: .record)
        pendingDisable = try values.decodeIfPresent(Bool.self, forKey: .pendingDisable) ?? false
    }
}

struct BundledServiceActivation {
    static let canonicalAppURL = URL(fileURLWithPath: "/Applications/Switchboard.app", isDirectory: true)

    let fileSystem: any BundledServiceActivationFileSystem
    let servicesDirectoryURL: URL
    let recoveryRootURL: URL

    init(
        fileSystem: any BundledServiceActivationFileSystem = LocalBundledServiceActivationFileSystem(),
        servicesDirectoryURL: URL? = nil,
        recoveryRootURL: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileSystem = fileSystem
        self.servicesDirectoryURL = servicesDirectoryURL ?? home.appendingPathComponent("Library/Services", isDirectory: true)
        self.recoveryRootURL = recoveryRootURL ?? home.appendingPathComponent(
            "Library/Application Support/Switchboard/BundledServiceActivation",
            isDirectory: true
        )
    }

    func enable(bundleURL: URL, serviceNames: [String]) throws {
        try validateCanonical(bundleURL)
        let names = try validateServiceNames(serviceNames)
        guard !names.isEmpty else { return }

        for serviceName in names {
            try validateSource(sourceURL(bundleURL: Self.canonicalAppURL, serviceName: serviceName))
        }

        try fileSystem.createDirectory(at: servicesDirectoryURL, permissions: 0o700)
        try fileSystem.createDirectory(at: recoveryRootURL, permissions: 0o700)

        var records: [BundledServiceActivationRecord] = []
        do {
            for serviceName in names {
                try enableOne(bundleURL: Self.canonicalAppURL, serviceName: serviceName, records: &records)
            }
        } catch {
            try rollback(records)
            throw error
        }
    }

    func disable(bundleURL: URL, serviceNames: [String]) throws {
        try validateCanonical(bundleURL)
        let names = try validateServiceNames(serviceNames)
        for serviceName in names {
            try disableOne(serviceName: serviceName)
        }
    }

    private func enableOne(
        bundleURL: URL,
        serviceName: String,
        records: inout [BundledServiceActivationRecord]
    ) throws {
        let source = sourceURL(bundleURL: bundleURL, serviceName: serviceName)
        try validateSource(source)
        let destination = servicesDirectoryURL.appendingPathComponent(serviceName)
        let existing = try fileSystem.metadata(at: destination)
        if let existing {
            if existing.isSymbolicLink { throw BundledServiceActivationError.legacyItemIsSymbolicLink(destination) }
            if !existing.isDirectory { throw BundledServiceActivationError.legacyItemIsNotDirectory(destination) }
        }

        let transactionDirectory = recoveryRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileSystem.createDirectory(at: transactionDirectory, permissions: 0o700)
        let stage = servicesDirectoryURL.appendingPathComponent(".switchboard-stage-\(UUID().uuidString)-\(serviceName)", isDirectory: true)
        let digest: String
        do {
            try fileSystem.copyItem(at: source, to: stage)
            digest = try treeDigest(at: stage)
        } catch {
            do {
                if try fileSystem.metadata(at: stage) != nil { try fileSystem.removeItem(at: stage) }
                try fileSystem.removeItem(at: transactionDirectory)
            } catch {
                throw BundledServiceActivationError.rollbackFailed(String(describing: error))
            }
            throw error
        }
        let legacyBackup = existing == nil ? nil : transactionDirectory.appendingPathComponent(serviceName + ".legacy", isDirectory: true)
        let legacyTreeDigest = existing == nil ? nil : try treeDigest(at: destination)
        let record = BundledServiceActivationRecord(
            serviceName: serviceName,
            destinationURL: destination,
            stageURL: stage,
            transactionDirectory: transactionDirectory,
            legacyBackupURL: legacyBackup,
            installedTreeDigest: digest,
            legacyTreeDigest: legacyTreeDigest
        )
        records.append(record)
        let intentURL = transactionDirectory.appendingPathComponent(serviceName + ".intent.json")
        try persist(BundledServiceActivationState(schemaVersion: 1, serviceName: serviceName, record: record), to: intentURL)

        if let legacyBackup { try fileSystem.moveItem(at: destination, to: legacyBackup) }
        try fileSystem.atomicallyMoveItem(at: stage, to: destination)
        try persist(BundledServiceActivationState(schemaVersion: 1, serviceName: serviceName, record: record), to: stateURL(for: serviceName))
    }

    private func disableOne(serviceName: String) throws {
        let stateURL = stateURL(for: serviceName)
        guard let stateMetadata = try fileSystem.metadata(at: stateURL) else { return }
        guard !stateMetadata.isSymbolicLink, stateMetadata.isRegularFile else {
            throw BundledServiceActivationError.stateCorrupt(stateURL)
        }
        let state: BundledServiceActivationState
        do {
            state = try JSONDecoder().decode(BundledServiceActivationState.self, from: fileSystem.readData(at: stateURL))
        } catch {
            throw BundledServiceActivationError.stateCorrupt(stateURL)
        }
        try validatePersistedState(state)

        guard let destinationMetadata = try fileSystem.metadata(at: state.record.destinationURL) else {
            if let legacyBackup = state.record.legacyBackupURL,
               try fileSystem.metadata(at: legacyBackup) != nil {
                var pending = state
                try persistDisableIntent(&pending)
                try fileSystem.moveItem(at: legacyBackup, to: state.record.destinationURL)
                pending.pendingDisable = false
                try cleanup(pending)
            } else if state.pendingDisable {
                // A completed restore may have happened just before a crash. The
                // durable legacy digest lets us distinguish that state from a
                // foreign replacement without deleting anything.
                if state.record.legacyBackupURL == nil {
                    // There was no legacy item to restore; the owned copy was
                    // removed and only cleanup remained when the crash occurred.
                    try cleanup(state)
                } else {
                    try cleanupIfRestored(state)
                }
            }
            return
        }
        guard destinationMetadata.isDirectory, !destinationMetadata.isSymbolicLink else { return }
        let destinationDigest = try treeDigest(at: state.record.destinationURL)
        guard destinationDigest == state.record.installedTreeDigest else {
            if state.pendingDisable, destinationDigest == state.record.legacyTreeDigest {
                try cleanup(state)
            }
            return
        }

        var pending = state
        try persistDisableIntent(&pending)
        try fileSystem.removeItem(at: state.record.destinationURL)
        if let legacyBackup = state.record.legacyBackupURL {
            // Keep the pending marker durable across the removal and before the
            // legacy directory is restored. A crash in either window is resumed
            // safely by the next disable call.
            try persistDisableIntent(&pending)
            try fileSystem.moveItem(at: legacyBackup, to: state.record.destinationURL)
        }
        pending.pendingDisable = false
        try cleanup(pending)
    }

    private func validateSource(_ source: URL) throws {
        guard let metadata = try fileSystem.metadata(at: source) else {
            throw BundledServiceActivationError.sourceMissing(source)
        }
        if metadata.isSymbolicLink { throw BundledServiceActivationError.sourceIsSymbolicLink(source) }
        if !metadata.isDirectory { throw BundledServiceActivationError.sourceIsNotDirectory(source) }
        let info = source.appendingPathComponent("Contents/Info.plist")
        let document = source.appendingPathComponent("Contents/document.wflow")
        try validateRequiredFile(info)
        try validateRequiredFile(document)
    }

    private func validateRequiredFile(_ url: URL) throws {
        guard let metadata = try fileSystem.metadata(at: url) else {
            throw BundledServiceActivationError.requiredFileMissing(url)
        }
        if metadata.isSymbolicLink { throw BundledServiceActivationError.requiredFileIsSymbolicLink(url) }
        if !metadata.isRegularFile { throw BundledServiceActivationError.requiredFileIsNotRegular(url) }
    }

    private func validateCanonical(_ bundleURL: URL) throws {
        guard bundleURL.resolvingSymlinksInPath().standardizedFileURL == Self.canonicalAppURL else {
            throw BundledServiceActivationError.nonCanonicalBundle(bundleURL)
        }
    }

    private func validateServiceNames(_ names: [String]) throws -> [String] {
        var seen = Set<String>()
        for name in names {
            guard isValidServiceName(name) else { throw BundledServiceActivationError.invalidServiceName(name) }
            seen.insert(name)
        }
        return names.filter { seen.remove($0) != nil }
    }

    private func isValidServiceName(_ name: String) -> Bool {
        name.hasSuffix(".workflow") && name.count > ".workflow".count &&
            name != ".workflow" && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private func sourceURL(bundleURL: URL, serviceName: String) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources/Services", isDirectory: true)
            .appendingPathComponent(serviceName, isDirectory: true)
    }

    private func stateURL(for serviceName: String) -> URL {
        recoveryRootURL.appendingPathComponent(serviceName + ".switchboard-state.json")
    }

    private func persist(_ state: BundledServiceActivationState, to url: URL) throws {
        let data = try JSONEncoder.sorted.encode(state)
        try fileSystem.writeDataAtomically(data, to: url, permissions: 0o600)
    }

    private func persistDisableIntent(_ state: inout BundledServiceActivationState) throws {
        state.pendingDisable = true
        try persist(
            state,
            to: state.record.transactionDirectory.appendingPathComponent(state.serviceName + ".intent.json")
        )
        try persist(state, to: stateURL(for: state.serviceName))
    }

    private func treeDigest(at url: URL) throws -> String {
        let entries = try fileSystem.treeSnapshot(at: url).sorted { $0.relativePath < $1.relativePath }
        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: try JSONEncoder.sorted.encode(entry))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validatePersistedState(_ state: BundledServiceActivationState) throws {
        guard state.schemaVersion == 1, state.serviceName == state.record.serviceName,
              isValidServiceName(state.serviceName) else {
            throw BundledServiceActivationError.stateCorrupt(stateURL(for: state.serviceName))
        }
        let expectedDestination = servicesDirectoryURL.appendingPathComponent(state.serviceName).standardizedFileURL
        guard state.record.destinationURL.standardizedFileURL == expectedDestination else {
            throw BundledServiceActivationError.stateCorrupt(stateURL(for: state.serviceName))
        }
        let recoveryPrefix = recoveryRootURL.standardizedFileURL.path + "/"
        guard state.record.transactionDirectory.standardizedFileURL.path.hasPrefix(recoveryPrefix),
              state.record.stageURL.standardizedFileURL.path.hasPrefix(servicesDirectoryURL.standardizedFileURL.path + "/") else {
            throw BundledServiceActivationError.stateCorrupt(stateURL(for: state.serviceName))
        }
        if let backup = state.record.legacyBackupURL {
            guard backup.standardizedFileURL.path.hasPrefix(state.record.transactionDirectory.standardizedFileURL.path + "/") else {
                throw BundledServiceActivationError.stateCorrupt(stateURL(for: state.serviceName))
            }
        }
    }

    private func cleanupIfRestored(_ state: BundledServiceActivationState) throws {
        guard let expectedLegacyDigest = state.record.legacyTreeDigest,
              let destinationMetadata = try fileSystem.metadata(at: state.record.destinationURL),
              destinationMetadata.isDirectory,
              !destinationMetadata.isSymbolicLink,
              try treeDigest(at: state.record.destinationURL) == expectedLegacyDigest else {
            return
        }
        try cleanup(state)
    }

    private func rollback(_ records: [BundledServiceActivationRecord]) throws {
        do {
            for record in records.reversed() {
                if let destinationMetadata = try fileSystem.metadata(at: record.destinationURL), destinationMetadata.isDirectory, !destinationMetadata.isSymbolicLink {
                    if try treeDigest(at: record.destinationURL) == record.installedTreeDigest {
                        try fileSystem.removeItem(at: record.destinationURL)
                    }
                }
                if let backup = record.legacyBackupURL, try fileSystem.metadata(at: backup) != nil,
                   try fileSystem.metadata(at: record.destinationURL) == nil {
                    try fileSystem.moveItem(at: backup, to: record.destinationURL)
                }
                if try fileSystem.metadata(at: record.stageURL) != nil { try fileSystem.removeItem(at: record.stageURL) }
                try fileSystem.removeItem(at: stateURL(for: record.serviceName))
                try fileSystem.removeItem(at: record.transactionDirectory)
            }
        } catch {
            throw BundledServiceActivationError.rollbackFailed(String(describing: error))
        }
    }

    private func cleanup(_ state: BundledServiceActivationState) throws {
        try fileSystem.removeItem(at: stateURL(for: state.serviceName))
        try fileSystem.removeItem(at: state.record.transactionDirectory)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

struct LocalBundledServiceActivationFileSystem: BundledServiceActivationFileSystem {
    private let fileManager = FileManager.default

    func metadata(at url: URL) throws -> BundledServiceFileMetadata? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
        catch CocoaError.fileNoSuchFile { return nil }
        let type = attributes[.type] as? FileAttributeType
        return .init(
            isRegularFile: type == .typeRegular,
            isDirectory: type == .typeDirectory,
            isSymbolicLink: type == .typeSymbolicLink,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    func readData(at url: URL) throws -> Data { try Data(contentsOf: url) }

    func createDirectory(at url: URL, permissions: UInt16) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    func writeDataAtomically(_ data: Data, to url: URL, permissions: UInt16) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: temp.path)
        if try metadata(at: url) != nil {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    func copyItem(at source: URL, to destination: URL) throws { try fileManager.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) throws { try fileManager.moveItem(at: source, to: destination) }

    func atomicallyMoveItem(at source: URL, to destination: URL) throws {
        if try metadata(at: destination) != nil {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    func removeItem(at url: URL) throws {
        guard try metadata(at: url) != nil else { return }
        try fileManager.removeItem(at: url)
    }

    func treeSnapshot(at url: URL) throws -> [BundledServiceTreeEntry] {
        var entries: [BundledServiceTreeEntry] = []
        try appendSnapshot(url, relativePath: "", into: &entries)
        return entries
    }

    private func appendSnapshot(_ url: URL, relativePath: String, into entries: inout [BundledServiceTreeEntry]) throws {
        guard let metadata = try metadata(at: url) else { return }
        let data = metadata.isRegularFile ? try readData(at: url) : nil
        entries.append(.init(relativePath: relativePath, metadata: metadata, data: data))
        guard metadata.isDirectory, !metadata.isSymbolicLink else { return }
        for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let childPath = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
            try appendSnapshot(child, relativePath: childPath, into: &entries)
        }
    }
}
