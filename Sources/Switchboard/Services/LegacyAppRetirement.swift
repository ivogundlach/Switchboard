import CryptoKit
import Foundation

enum LegacyAppRetirementPhase: String, Codable {
    case planned
    case archiveIntent
    case archived
    case trashIntent
    case retired
}

struct LegacyAppRetirementJournal: Codable, Equatable {
    let schemaVersion: Int
    let transactionID: UUID
    let componentID: String
    let sourcePath: String
    let bundleID: String
    let executableName: String
    let sourceDigest: String
    let designatedRequirement: String
    let archivePath: String
    var trashPath: String?
    var phase: LegacyAppRetirementPhase
}

enum LegacyAppRetirementError: LocalizedError {
    case invalidContract
    case sourceMissing
    case unsafePath(String)
    case identityMismatch(String)
    case untrustedSignature(String)
    case archiveFailed(String)
    case verificationFailed(String)
    case trashFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidContract: "The legacy app retirement contract is incomplete."
        case .sourceMissing: "The exact legacy app is no longer installed."
        case .unsafePath(let detail): "The legacy app path is unsafe: \(detail)"
        case .identityMismatch(let detail): "The legacy app identity does not match: \(detail)"
        case .untrustedSignature(let detail): "The legacy app has an unrecognized signing identity: \(detail)"
        case .archiveFailed(let detail): "The recovery archive could not be created: \(detail)"
        case .verificationFailed(let detail): "The recovery archive could not be verified: \(detail)"
        case .trashFailed(let detail): "The legacy app could not be moved to Trash: \(detail)"
        }
    }
}

final class LegacyAppRetirement {
    private static let developerTeamID = "Q2X7X86GYR"
    private static let historicalLeaf = "12f05e96dc78def756913a2d574ff98f6c5bd485"

    private let supportURL: URL
    private let fileManager: FileManager

    init(
        supportURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Switchboard", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.supportURL = supportURL
        self.fileManager = fileManager
    }

    func retire(_ component: UpgradeLegacyComponent) throws -> LegacyAppRetirementJournal {
        guard component.kind == .appBundle,
              component.disposition == .migrate,
              let path = component.canonicalPath,
              let bundleID = component.bundleID,
              let executableName = component.executableName else {
            throw LegacyAppRetirementError.invalidContract
        }
        let source = URL(fileURLWithPath: path, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { throw LegacyAppRetirementError.sourceMissing }
        let identity = try validate(source, bundleID: bundleID, executableName: executableName)
        let digest = try treeDigest(source)
        let transactionID = UUID()
        let recoveryRoot = supportURL
            .appending(path: "Recovery/LegacyApps/\(transactionID.uuidString)", directoryHint: .isDirectory)
        let archive = recoveryRoot.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        let journalURL = recoveryRoot.appending(path: "retirement.json")
        try ensurePrivateRecoveryPath(through: recoveryRoot)
        var journal = LegacyAppRetirementJournal(
            schemaVersion: 1,
            transactionID: transactionID,
            componentID: component.id,
            sourcePath: source.path,
            bundleID: bundleID,
            executableName: executableName,
            sourceDigest: digest,
            designatedRequirement: identity,
            archivePath: archive.path,
            trashPath: nil,
            phase: .planned
        )
        try persist(journal, at: journalURL)

        journal.phase = .archiveIntent
        try persist(journal, at: journalURL)
        let copy = run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", source.path, archive.path])
        guard copy.status == 0 else { throw LegacyAppRetirementError.archiveFailed(copy.error) }
        let archiveIdentity = try validate(
            archive,
            bundleID: bundleID,
            executableName: executableName,
            allowRecoveryPath: true
        )
        guard archiveIdentity == identity, try treeDigest(archive) == digest else {
            throw LegacyAppRetirementError.verificationFailed("the archived copy does not match the installed app")
        }
        try verifyRestorable(
            archive: archive,
            expectedBundleID: bundleID,
            expectedExecutableName: executableName,
            expectedIdentity: identity,
            expectedDigest: digest,
            under: recoveryRoot
        )
        journal.phase = .archived
        try persist(journal, at: journalURL)

        journal.phase = .trashIntent
        try persist(journal, at: journalURL)
        var resultingURL: NSURL?
        do {
            try fileManager.trashItem(at: source, resultingItemURL: &resultingURL)
        } catch {
            throw LegacyAppRetirementError.trashFailed(error.localizedDescription)
        }
        guard !fileManager.fileExists(atPath: source.path), let resultingURL else {
            throw LegacyAppRetirementError.trashFailed("the canonical app remains in Applications")
        }
        journal.trashPath = (resultingURL as URL).path
        journal.phase = .retired
        try persist(journal, at: journalURL)
        return journal
    }

    @discardableResult
    func reconcileInterruptedRetirements() throws -> Int {
        let root = supportURL.appending(path: "Recovery/LegacyApps", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        try validatePrivateRecoveryPath(through: root)
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var reconciled = 0
        for directory in entries {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let journalURL = directory.appending(path: "retirement.json")
            guard fileManager.fileExists(atPath: journalURL.path) else { continue }
            var journal = try JSONDecoder().decode(
                LegacyAppRetirementJournal.self,
                from: Data(contentsOf: journalURL)
            )
            guard journal.schemaVersion == 1,
                  journal.transactionID.uuidString == directory.lastPathComponent,
                  UpgradeLegacyComponent.isSafeAppPath(journal.sourcePath),
                  journal.archivePath.hasPrefix(directory.path + "/") else {
                throw LegacyAppRetirementError.verificationFailed("an interrupted retirement journal is malformed")
            }
            let sourceExists = fileManager.fileExists(atPath: journal.sourcePath)
            let archiveURL = URL(fileURLWithPath: journal.archivePath, isDirectory: true)
            let archiveExists = fileManager.fileExists(atPath: archiveURL.path)
            if archiveExists {
                _ = try validate(
                    archiveURL,
                    bundleID: journal.bundleID,
                    executableName: journal.executableName,
                    allowRecoveryPath: true
                )
                guard try treeDigest(archiveURL) == journal.sourceDigest else {
                    throw LegacyAppRetirementError.verificationFailed("an interrupted recovery archive does not match")
                }
            }
            switch journal.phase {
            case .planned, .archiveIntent:
                if archiveExists {
                    journal.phase = .archived
                    try persist(journal, at: journalURL)
                    reconciled += 1
                }
            case .archived:
                // The source still exists and no retirement intent was written.
                // Leave it installed for the next explicit review.
                break
            case .trashIntent:
                if !sourceExists, archiveExists {
                    journal.phase = .retired
                    try persist(journal, at: journalURL)
                    reconciled += 1
                }
            case .retired:
                guard !sourceExists, archiveExists else {
                    throw LegacyAppRetirementError.verificationFailed("a completed retirement lost its recovery invariant")
                }
            }
        }
        return reconciled
    }

    @discardableResult
    func validate(
        _ appURL: URL,
        bundleID: String,
        executableName: String,
        allowRecoveryPath: Bool = false
    ) throws -> String {
        let isRecoveryPath = appURL.standardizedFileURL.path.hasPrefix(
            supportURL.appending(path: "Recovery/LegacyApps", directoryHint: .isDirectory).standardizedFileURL.path + "/"
        )
        guard UpgradeLegacyComponent.isSafeAppPath(appURL.path) || (allowRecoveryPath && isRecoveryPath) else {
            throw LegacyAppRetirementError.unsafePath(appURL.path)
        }
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let parentIsSafe: Bool
        if allowRecoveryPath {
            parentIsSafe = true
        } else {
            parentIsSafe = try isRegularDirectory(applications)
        }
        let appIsSafe = try isRegularDirectory(appURL)
        guard parentIsSafe, appIsSafe else {
            throw LegacyAppRetirementError.unsafePath("a path component is not a regular directory")
        }
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == executableName else {
            throw LegacyAppRetirementError.identityMismatch(bundleID)
        }
        let executable = appURL.appending(path: "Contents/MacOS/\(executableName)")
        let executableAttributes = try fileManager.attributesOfItem(atPath: executable.path)
        guard executableAttributes[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw LegacyAppRetirementError.unsafePath("the declared executable is missing or is a link")
        }
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", appURL.path])
        guard verify.status == 0 else { throw LegacyAppRetirementError.untrustedSignature(verify.error) }
        let display = run("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", appURL.path])
        guard display.status == 0 else { throw LegacyAppRetirementError.untrustedSignature(display.error) }
        let combinedOutput = display.output + "\n" + display.error
        guard let requirement = Self.designatedRequirement(in: combinedOutput) else {
            throw LegacyAppRetirementError.untrustedSignature("designated requirement missing")
        }
        let accepted = Self.acceptsDesignatedRequirement(requirement)
        guard accepted else { throw LegacyAppRetirementError.untrustedSignature("unmatched designated requirement") }
        return requirement
    }

    static func acceptsDesignatedRequirement(_ requirement: String) -> Bool {
        let normalized = requirement.lowercased()
        return normalized.contains("anchor apple generic")
            && normalized.contains("certificate leaf[subject.ou] = \(developerTeamID.lowercased())")
            || normalized.contains("certificate leaf = h\"\(historicalLeaf)\"")
    }

    static func designatedRequirement(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.lowercased().hasPrefix("designated =>") }?
            .lowercased()
    }

    private func isRegularDirectory(_ url: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private func ensurePrivateRecoveryPath(through transactionRoot: URL) throws {
        let recovery = supportURL.appending(path: "Recovery", directoryHint: .isDirectory)
        let legacyApps = recovery.appending(path: "LegacyApps", directoryHint: .isDirectory)
        try privateDirectory(supportURL, createIntermediates: true)
        try privateDirectory(recovery, createIntermediates: false)
        try privateDirectory(legacyApps, createIntermediates: false)
        try privateDirectory(transactionRoot, createIntermediates: false)
    }

    private func validatePrivateRecoveryPath(through root: URL) throws {
        for directory in [
            supportURL,
            supportURL.appending(path: "Recovery", directoryHint: .isDirectory),
            root,
        ] {
            try privateDirectory(directory, createIntermediates: false)
        }
    }

    private func privateDirectory(_ url: URL, createIntermediates: Bool) throws {
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
            throw LegacyAppRetirementError.unsafePath("\(url.path) is not an owner-owned directory")
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try validatePrivateDirectory(url)
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0 else {
            throw LegacyAppRetirementError.unsafePath("\(url.path) is not an owner-only directory")
        }
    }

    private func verifyRestorable(
        archive: URL,
        expectedBundleID: String,
        expectedExecutableName: String,
        expectedIdentity: String,
        expectedDigest: String,
        under recoveryRoot: URL
    ) throws {
        let restored = recoveryRoot.appending(
            path: ".restore-verification-\(UUID().uuidString).app",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: restored) }
        let copy = run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", archive.path, restored.path])
        guard copy.status == 0 else {
            throw LegacyAppRetirementError.verificationFailed("the recovery copy could not be restored: \(copy.error)")
        }
        let identity = try validate(
            restored,
            bundleID: expectedBundleID,
            executableName: expectedExecutableName,
            allowRecoveryPath: true
        )
        guard identity == expectedIdentity, try treeDigest(restored) == expectedDigest else {
            throw LegacyAppRetirementError.verificationFailed("a restored recovery copy does not match")
        }
    }

    private func persist(_ journal: LegacyAppRetirementJournal, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func treeDigest(_ root: URL) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw LegacyAppRetirementError.verificationFailed("the app could not be enumerated") }
        var entries = [String]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw LegacyAppRetirementError.unsafePath("the app contains a symbolic link")
            }
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let relative = String(url.path.dropFirst(root.path.count + 1))
            entries.append("\(relative)\u{0}\(data.count)\u{0}\(hash)")
        }
        let manifest = entries.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
