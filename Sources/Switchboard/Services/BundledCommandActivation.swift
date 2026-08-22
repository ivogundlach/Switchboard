import Foundation

protocol BundledCommandActivationFileSystem {
    func metadata(at url: URL) throws -> BundledCommandFileMetadata?
    func readData(at url: URL) throws -> Data
    func readSymbolicLink(at url: URL) throws -> URL
    func createDirectory(at url: URL, permissions: UInt16) throws
    func writeData(_ data: Data, to url: URL, permissions: UInt16) throws
    func writeDataAtomically(_ data: Data, to url: URL, permissions: UInt16) throws
    func setMetadata(_ metadata: BundledCommandFileMetadata, at url: URL) throws
    func removeItem(at url: URL) throws
    func createSymbolicLink(at url: URL, pointingTo target: URL) throws
    func atomicallyReplaceItem(at url: URL, withSymbolicLinkTo target: URL) throws
}

struct BundledCommandFileMetadata: Codable, Equatable {
    let isRegularFile: Bool
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let posixPermissions: UInt16
    let modificationDate: Date?
}

enum BundledCommandActivationError: Error, Equatable {
    case nonCanonicalBundle(URL)
    case invalidModuleID(String)
    case invalidCommandName(String)
    case sourceMissing(URL)
    case sourceIsSymbolicLink(URL)
    case sourceIsNotRegular(URL)
    case sourceIsNotExecutable(URL)
    case legacyItemIsSymbolicLink(URL)
    case legacyItemIsNotRegular(URL)
    case stateCorrupt(URL)
    case rollbackFailed(String)
}

private struct BundledCommandActivationRecord: Codable, Equatable {
    let commandName: String
    let targetURL: URL
    let destinationURL: URL
    let backupURL: URL?
    let legacyMetadata: BundledCommandFileMetadata?
}

private struct BundledCommandActivationState: Codable, Equatable {
    let schemaVersion: Int
    let moduleID: String
    let transactionDirectory: URL
    var records: [BundledCommandActivationRecord]
    /// Names whose disable operation is durable and may be resumed after a crash.
    var pendingDisable: [String]

    init(
        schemaVersion: Int,
        moduleID: String,
        transactionDirectory: URL,
        records: [BundledCommandActivationRecord],
        pendingDisable: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.moduleID = moduleID
        self.transactionDirectory = transactionDirectory
        self.records = records
        self.pendingDisable = pendingDisable
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, moduleID, transactionDirectory, records, pendingDisable
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        moduleID = try values.decode(String.self, forKey: .moduleID)
        transactionDirectory = try values.decode(URL.self, forKey: .transactionDirectory)
        records = try values.decode([BundledCommandActivationRecord].self, forKey: .records)
        pendingDisable = try values.decodeIfPresent([String].self, forKey: .pendingDisable) ?? []
    }
}

struct BundledCommandActivation {
    static let canonicalAppURL = URL(fileURLWithPath: "/Applications/Switchboard.app", isDirectory: true)

    let fileSystem: any BundledCommandActivationFileSystem
    let localBinURL: URL
    let recoveryRootURL: URL

    init(
        fileSystem: any BundledCommandActivationFileSystem = LocalBundledCommandActivationFileSystem(),
        localBinURL: URL? = nil,
        recoveryRootURL: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileSystem = fileSystem
        self.localBinURL = localBinURL ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        self.recoveryRootURL = recoveryRootURL ?? home.appendingPathComponent(
            "Library/Application Support/Switchboard/BundledCommandActivation",
            isDirectory: true
        )
    }

    func enable(bundleURL: URL, moduleID: String, commandNames: [String]) throws {
        try validateCanonical(bundleURL)
        try validateModuleID(moduleID)
        let names = try validateCommandNames(commandNames)
        guard !names.isEmpty else { return }

        let sources = try names.map { name in
            let source = sourceURL(bundleURL: Self.canonicalAppURL, moduleID: moduleID, commandName: name)
            try validateSource(source)
            return (name, source)
        }

        try fileSystem.createDirectory(at: localBinURL, permissions: 0o700)
        let moduleRecoveryURL = recoveryRootURL.appendingPathComponent(moduleID, isDirectory: true)
        try fileSystem.createDirectory(at: recoveryRootURL, permissions: 0o700)
        try fileSystem.createDirectory(at: moduleRecoveryURL, permissions: 0o700)

        let transactionURL = moduleRecoveryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileSystem.createDirectory(at: transactionURL, permissions: 0o700)

        var records: [BundledCommandActivationRecord] = []
        do {
            for (name, _) in sources {
                let destination = localBinURL.appendingPathComponent(name)
                let target = Self.canonicalAppURL
                    .appendingPathComponent("Contents/Resources/Modules", isDirectory: true)
                    .appendingPathComponent(moduleID, isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(name)
                let metadata = try fileSystem.metadata(at: destination)
                if let metadata {
                    if metadata.isSymbolicLink {
                        let existingTarget = try fileSystem.readSymbolicLink(at: destination)
                        guard existingTarget.standardizedFileURL == target.standardizedFileURL else {
                            throw BundledCommandActivationError.legacyItemIsSymbolicLink(destination)
                        }
                        records.append(.init(commandName: name, targetURL: target, destinationURL: destination, backupURL: nil, legacyMetadata: nil))
                    } else if !metadata.isRegularFile {
                        throw BundledCommandActivationError.legacyItemIsNotRegular(destination)
                    } else {
                        let backup = transactionURL.appendingPathComponent(name + ".legacy")
                        try fileSystem.writeData(try fileSystem.readData(at: destination), to: backup, permissions: 0o600)
                        records.append(.init(commandName: name, targetURL: target, destinationURL: destination, backupURL: backup, legacyMetadata: metadata))
                    }
                } else {
                    records.append(.init(commandName: name, targetURL: target, destinationURL: destination, backupURL: nil, legacyMetadata: nil))
                }
            }

            let state = BundledCommandActivationState(
                schemaVersion: 1,
                moduleID: moduleID,
                transactionDirectory: transactionURL,
                records: records
            )
            try persist(state, named: "intent.json", under: transactionURL)
            try persist(state, named: "state.json", under: moduleRecoveryURL)

            var installed: [BundledCommandActivationRecord] = []
            do {
                for record in records {
                    try fileSystem.atomicallyReplaceItem(at: record.destinationURL, withSymbolicLinkTo: record.targetURL)
                    installed.append(record)
                }
            } catch {
                try rollback(installed + records.dropFirst(installed.count), state: state)
                throw error
            }
        } catch {
            if let activationError = error as? BundledCommandActivationError { throw activationError }
            throw error
        }
    }

    func disable(bundleURL: URL, moduleID: String, commandNames: [String]) throws {
        try validateCanonical(bundleURL)
        try validateModuleID(moduleID)
        let names = try validateCommandNames(commandNames)
        guard !names.isEmpty else { return }

        let moduleRecoveryURL = recoveryRootURL.appendingPathComponent(moduleID, isDirectory: true)
        let stateURL = moduleRecoveryURL.appendingPathComponent("state.json")
        let state: BundledCommandActivationState?
        if let stateMetadata = try fileSystem.metadata(at: stateURL) {
            guard !stateMetadata.isSymbolicLink, !stateMetadata.isDirectory else {
                throw BundledCommandActivationError.stateCorrupt(stateURL)
            }
            do {
                state = try JSONDecoder().decode(BundledCommandActivationState.self, from: fileSystem.readData(at: stateURL))
            } catch {
                throw BundledCommandActivationError.stateCorrupt(stateURL)
            }
        } else {
            state = nil
        }
        if let state {
            try validatePersistedState(state, moduleID: moduleID, moduleRecoveryURL: moduleRecoveryURL)
        }

        var workingState = state
        var remaining = state?.records ?? []
        for name in names {
            let target = sourceURL(bundleURL: Self.canonicalAppURL, moduleID: moduleID, commandName: name)
            let destination = localBinURL.appendingPathComponent(name)
            var record = remaining.first(where: { $0.commandName == name })
            let destinationMetadata = try fileSystem.metadata(at: destination)
            let ownedTarget = destinationMetadata?.isSymbolicLink == true &&
                (try? fileSystem.readSymbolicLink(at: destination))?.standardizedFileURL == target.standardizedFileURL

            // A stale state file may be absent after an interrupted enable. If the
            // destination is nevertheless our symlink, create an owner-only record
            // before touching it so the disable remains recoverable.
            if ownedTarget, record == nil {
                let transactionURL: URL
                if let existingState = workingState {
                    transactionURL = existingState.transactionDirectory
                } else {
                    let moduleRecoveryURL = recoveryRootURL.appendingPathComponent(moduleID, isDirectory: true)
                    try fileSystem.createDirectory(at: recoveryRootURL, permissions: 0o700)
                    try fileSystem.createDirectory(at: moduleRecoveryURL, permissions: 0o700)
                    transactionURL = moduleRecoveryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fileSystem.createDirectory(at: transactionURL, permissions: 0o700)
                    workingState = BundledCommandActivationState(
                        schemaVersion: 1,
                        moduleID: moduleID,
                        transactionDirectory: transactionURL,
                        records: []
                    )
                }
                let synthetic = BundledCommandActivationRecord(
                    commandName: name,
                    targetURL: target,
                    destinationURL: destination,
                    backupURL: nil,
                    legacyMetadata: nil
                )
                workingState?.records.append(synthetic)
                remaining.append(synthetic)
                record = synthetic
                if let newState = workingState {
                    try persist(newState, named: "intent.json", under: transactionURL)
                    try persist(newState, named: "state.json", under: moduleRecoveryURL)
                }
            }

            guard let metadata = try fileSystem.metadata(at: destination) else {
                if let record, record.backupURL != nil {
                    guard var pendingState = workingState else { continue }
                    try markPendingDisable(name, in: &pendingState)
                    try persist(pendingState, named: "intent.json", under: pendingState.transactionDirectory)
                    try persist(pendingState, named: "state.json", under: moduleRecoveryURL)
                    if try restore(record) {
                        pendingState.pendingDisable.removeAll { $0 == name }
                        pendingState.records.removeAll { $0.commandName == name }
                        workingState = pendingState
                        remaining.removeAll { $0.commandName == name }
                    } else {
                        workingState = pendingState
                    }
                } else if let record, workingState?.pendingDisable.contains(name) == true {
                    // The owned symlink may already have been removed before a
                    // crash. With no legacy backup there is nothing left to
                    // restore, so completing the durable intent is safe.
                    workingState?.pendingDisable.removeAll { $0 == name }
                    workingState?.records.removeAll { $0.commandName == record.commandName }
                    remaining.removeAll { $0.commandName == name }
                }
                continue
            }
            if let record,
               workingState?.pendingDisable.contains(name) == true,
               metadata.isRegularFile,
               let backupURL = record.backupURL,
               let legacyMetadata = record.legacyMetadata,
               metadata == legacyMetadata,
               try fileSystem.metadata(at: backupURL) != nil,
               try fileSystem.readData(at: destination) == fileSystem.readData(at: backupURL) {
                // The prior process restored the exact legacy file and crashed
                // before clearing its durable disable intent. Keep foreign files
                // untouched; only exact bytes and metadata complete recovery.
                workingState?.pendingDisable.removeAll { $0 == name }
                workingState?.records.removeAll { $0.commandName == name }
                remaining.removeAll { $0.commandName == name }
                continue
            }
            guard metadata.isSymbolicLink, ownedTarget else { continue }
            guard var pendingState = workingState else {
                // The synthetic-record path above should always create state; keep
                // this guard as a safety belt if a custom filesystem races us.
                continue
            }
            try markPendingDisable(name, in: &pendingState)
            try persist(pendingState, named: "intent.json", under: pendingState.transactionDirectory)
            try persist(pendingState, named: "state.json", under: moduleRecoveryURL)
            try fileSystem.removeItem(at: destination)
            if let record {
                if record.backupURL != nil {
                    // Keep the pending marker durable across the removal and before
                    // restoring the legacy item. A crash in either window resumes
                    // safely on the next disable.
                    try persist(pendingState, named: "intent.json", under: pendingState.transactionDirectory)
                    try persist(pendingState, named: "state.json", under: moduleRecoveryURL)
                    guard try restore(record) else {
                        workingState = pendingState
                        continue
                    }
                }
                pendingState.pendingDisable.removeAll { $0 == name }
                pendingState.records.removeAll { $0.commandName == name }
                workingState = pendingState
                remaining.removeAll { $0.commandName == name }
            } else {
                pendingState.pendingDisable.removeAll { $0 == name }
                workingState = pendingState
            }
        }

        guard var finalState = workingState else { return }
        finalState.records = remaining
        if finalState.records.isEmpty, finalState.pendingDisable.isEmpty {
            try fileSystem.removeItem(at: stateURL)
            try fileSystem.removeItem(at: finalState.transactionDirectory)
        } else {
            try persist(finalState, named: "state.json", under: moduleRecoveryURL)
        }
    }

    private func validateCanonical(_ bundleURL: URL) throws {
        guard bundleURL.resolvingSymlinksInPath().standardizedFileURL == Self.canonicalAppURL else {
            throw BundledCommandActivationError.nonCanonicalBundle(bundleURL)
        }
    }

    private func validateModuleID(_ moduleID: String) throws {
        guard isSingleFilename(moduleID) else { throw BundledCommandActivationError.invalidModuleID(moduleID) }
    }

    private func validateCommandNames(_ names: [String]) throws -> [String] {
        var seen = Set<String>()
        for name in names {
            guard isSingleFilename(name) else { throw BundledCommandActivationError.invalidCommandName(name) }
            seen.insert(name)
        }
        return names.filter { seen.remove($0) != nil }
    }

    private func isSingleFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private func sourceURL(bundleURL: URL, moduleID: String, commandName: String) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources/Modules", isDirectory: true)
            .appendingPathComponent(moduleID, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(commandName)
    }

    private func validateSource(_ url: URL) throws {
        guard let metadata = try fileSystem.metadata(at: url) else { throw BundledCommandActivationError.sourceMissing(url) }
        if metadata.isSymbolicLink { throw BundledCommandActivationError.sourceIsSymbolicLink(url) }
        if !metadata.isRegularFile { throw BundledCommandActivationError.sourceIsNotRegular(url) }
        if metadata.posixPermissions & 0o111 == 0 { throw BundledCommandActivationError.sourceIsNotExecutable(url) }
    }

    private func validatePersistedState(
        _ state: BundledCommandActivationState,
        moduleID: String,
        moduleRecoveryURL: URL
    ) throws {
        let recoveryPrefix = moduleRecoveryURL.standardizedFileURL.path + "/"
        guard state.transactionDirectory.standardizedFileURL.path.hasPrefix(recoveryPrefix) else {
            throw BundledCommandActivationError.stateCorrupt(moduleRecoveryURL.appendingPathComponent("state.json"))
        }
        for record in state.records {
            guard isSingleFilename(record.commandName) else {
                throw BundledCommandActivationError.stateCorrupt(moduleRecoveryURL.appendingPathComponent("state.json"))
            }
            let expectedDestination = localBinURL.appendingPathComponent(record.commandName).standardizedFileURL
            let expectedTarget = sourceURL(bundleURL: Self.canonicalAppURL, moduleID: moduleID, commandName: record.commandName).standardizedFileURL
            guard record.destinationURL.standardizedFileURL == expectedDestination,
                  record.targetURL.standardizedFileURL == expectedTarget else {
                throw BundledCommandActivationError.stateCorrupt(moduleRecoveryURL.appendingPathComponent("state.json"))
            }
            if let backupURL = record.backupURL {
                guard backupURL.standardizedFileURL.path.hasPrefix(state.transactionDirectory.standardizedFileURL.path + "/") else {
                    throw BundledCommandActivationError.stateCorrupt(moduleRecoveryURL.appendingPathComponent("state.json"))
                }
            }
        }
    }

    private func persist(_ state: BundledCommandActivationState, named name: String, under directory: URL) throws {
        let data = try JSONEncoder.sorted.encode(state)
        try fileSystem.writeDataAtomically(data, to: directory.appendingPathComponent(name), permissions: 0o600)
    }

    private func markPendingDisable(_ name: String, in state: inout BundledCommandActivationState) throws {
        if !state.pendingDisable.contains(name) { state.pendingDisable.append(name) }
    }

    @discardableResult
    private func restore(_ record: BundledCommandActivationRecord) throws -> Bool {
        guard let backup = record.backupURL, let metadata = record.legacyMetadata else { return true }
        // Never overwrite a destination that appeared after the owned symlink was
        // removed. This preserves a foreign modification across crash recovery.
        guard try fileSystem.metadata(at: record.destinationURL) == nil else { return false }
        try fileSystem.writeData(try fileSystem.readData(at: backup), to: record.destinationURL, permissions: metadata.posixPermissions)
        try fileSystem.setMetadata(metadata, at: record.destinationURL)
        // Retain the exact backup until the durable state is cleared. If the
        // process crashes here, the next disable can prove the destination is
        // our completed restore instead of mistaking it for a foreign file.
        return true
    }

    private func rollback(_ records: [BundledCommandActivationRecord], state: BundledCommandActivationState) throws {
        do {
            for record in records.reversed() {
                guard let metadata = try fileSystem.metadata(at: record.destinationURL) else { continue }
                if metadata.isSymbolicLink,
                   let target = try? fileSystem.readSymbolicLink(at: record.destinationURL),
                   target.standardizedFileURL == record.targetURL.standardizedFileURL {
                    try fileSystem.removeItem(at: record.destinationURL)
                }
                _ = try restore(record)
            }
            let stateURL = state.transactionDirectory.deletingLastPathComponent().appendingPathComponent("state.json")
            try fileSystem.removeItem(at: stateURL)
            try fileSystem.removeItem(at: state.transactionDirectory)
        } catch {
            throw BundledCommandActivationError.rollbackFailed(String(describing: error))
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

struct LocalBundledCommandActivationFileSystem: BundledCommandActivationFileSystem {
    private let fileManager = FileManager.default

    func metadata(at url: URL) throws -> BundledCommandFileMetadata? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        let type = attributes[.type] as? FileAttributeType
        return BundledCommandFileMetadata(
            isRegularFile: type == .typeRegular,
            isDirectory: type == .typeDirectory,
            isSymbolicLink: type == .typeSymbolicLink,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    func readData(at url: URL) throws -> Data { try Data(contentsOf: url) }

    func readSymbolicLink(at url: URL) throws -> URL {
        URL(fileURLWithPath: try fileManager.destinationOfSymbolicLink(atPath: url.path))
    }

    func createDirectory(at url: URL, permissions: UInt16) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    func writeData(_ data: Data, to url: URL, permissions: UInt16) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    func writeDataAtomically(_ data: Data, to url: URL, permissions: UInt16) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try writeData(data, to: temporary, permissions: permissions)
        if try metadata(at: url) != nil {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    func setMetadata(_ metadata: BundledCommandFileMetadata, at url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: metadata.posixPermissions)]
        if let date = metadata.modificationDate { attributes[.modificationDate] = date }
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    func removeItem(at url: URL) throws {
        guard try metadata(at: url) != nil else { return }
        try fileManager.removeItem(at: url)
    }

    func createSymbolicLink(at url: URL, pointingTo target: URL) throws {
        try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
    }

    func atomicallyReplaceItem(at url: URL, withSymbolicLinkTo target: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".switchboard-\(UUID().uuidString)")
        defer { try? removeItem(at: temporary) }
        try createSymbolicLink(at: temporary, pointingTo: target)
        if try metadata(at: url) != nil {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
