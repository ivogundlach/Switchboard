import Foundation
import Darwin

/// Constants that are deliberately not configurable by update metadata or a command line caller.
public enum UpdateInstallerConstants {
    public static let canonicalTargetURL = URL(fileURLWithPath: "/Applications/Switchboard.app", isDirectory: true)
    public static let canonicalExecutableURL = URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard")
    public static let expectedBundleIdentifier = "com.ivogundlach.switchboard"
    public static let trustAnchorInfoPlistKey = "SwitchboardUpdateTeamIdentifier"
    public static let recoveryDirectoryName = "UpdateRecovery"
    public static let expectedExecutableName = "Switchboard"
}

public enum UpdateInstallerError: Error, LocalizedError, Equatable, Sendable {
    case missingTrustedTeamIdentifier
    case invalidTrustedTeamIdentifier
    case targetOverrideRejected(URL)
    case bundleIdentifierOverrideRejected(String)
    case invalidVersion
    case invalidPath(String)
    case pathTraversal(URL)
    case symbolicLink(URL)
    case missingPath(URL)
    case notDirectory(URL)
    case candidateCount(Int)
    case candidateNotUnderMountRoot(URL)
    case applicationSupportPermissions(URL, UInt16)
    case applicationSupportOwnership(URL)
    case invalidSibling(URL)
    case missingBundleIdentifier
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case missingBundleVersion
    case bundleVersionMismatch(expected: String, actual: String?)
    case missingArm64
    case codeSignatureRejected(Int32, String)
    case teamIdentifierMissing
    case teamIdentifierMismatch(expected: String, actual: String?)
    case designatedRequirementRejected
    case gatekeeperRejected(Int32, String)
    case commandFailed(String, Int32, String)
    case illegalTransition(from: UpdateInstallState, to: UpdateInstallState)
    case parentIdentityMismatch
    case transactionIdentityMismatch
    case mountOutputInvalid
    case transactionRecordPathInvalid
    case rollbackUnavailable
    case mountedRootUnavailable
    case invalidParentExecutable(URL)
    case hashNotVerified

    public var errorDescription: String? {
        switch self {
        case .missingTrustedTeamIdentifier: "The current bundle has no trusted update Team ID."
        case .invalidTrustedTeamIdentifier: "The current bundle's trusted update Team ID is invalid."
        case .targetOverrideRejected(let url): "The update target is fixed at /Applications/Switchboard.app; received \(url.path)."
        case .bundleIdentifierOverrideRejected(let id): "The update bundle identifier is fixed at com.ivogundlach.switchboard; received \(id)."
        case .invalidVersion: "The update version is empty or invalid."
        case .invalidPath(let reason): "The update path is invalid: \(reason)."
        case .pathTraversal(let url): "The update path contains traversal: \(url.path)."
        case .symbolicLink(let url): "The update path contains a symbolic link: \(url.path)."
        case .missingPath(let url): "The required path does not exist: \(url.path)."
        case .notDirectory(let url): "The required directory is not a directory: \(url.path)."
        case .candidateCount(let count): "Expected exactly one Switchboard.app candidate; found \(count)."
        case .candidateNotUnderMountRoot(let url): "The candidate is outside the supplied mount root: \(url.path)."
        case .applicationSupportPermissions(let url, let permissions): "Application Support must be owner-only at \(url.path) (mode \(String(permissions, radix: 8)))."
        case .applicationSupportOwnership(let url): "Application Support ownership could not be verified at \(url.path)."
        case .invalidSibling(let url): "The staging or backup path is not a sibling of the canonical target: \(url.path)."
        case .missingBundleIdentifier: "The candidate Info.plist has no bundle identifier."
        case .bundleIdentifierMismatch(let expected, let actual): "Candidate bundle identifier \(actual ?? "<missing>") does not equal \(expected)."
        case .missingBundleVersion: "The candidate Info.plist has no version."
        case .bundleVersionMismatch(let expected, let actual): "Candidate version \(actual ?? "<missing>") does not equal \(expected)."
        case .missingArm64: "The candidate does not contain an arm64 slice."
        case .codeSignatureRejected(let status, let output): "Strict deep code-signature verification failed (status \(status)): \(output)"
        case .teamIdentifierMissing: "The candidate code signature has no TeamIdentifier."
        case .teamIdentifierMismatch(let expected, let actual): "Candidate TeamIdentifier \(actual ?? "<missing>") does not equal the trusted Team ID \(expected)."
        case .designatedRequirementRejected: "The candidate is not signed by Apple's Developer ID Application certificate requirement."
        case .gatekeeperRejected(let status, let output): "Gatekeeper rejected the candidate (status \(status)): \(output)"
        case .commandFailed(let command, let status, let output): "Command \(command) failed (status \(status)): \(output)"
        case .illegalTransition(let from, let to): "Update state cannot transition from \(from.rawValue) to \(to.rawValue)."
        case .parentIdentityMismatch: "The recorded parent process identity no longer matches; PID reuse is unsafe."
        case .transactionIdentityMismatch: "The update layout and persisted transaction IDs do not match."
        case .mountOutputInvalid: "The read-only mount command did not return one safe mount point."
        case .transactionRecordPathInvalid: "The transaction record path is not a safe owner-only recovery path."
        case .rollbackUnavailable: "The verified recovery backup is unavailable for rollback."
        case .mountedRootUnavailable: "The interrupted update did not preserve a safe mounted-image path for cleanup."
        case .invalidParentExecutable(let url): "The recorded parent executable is not the canonical Switchboard executable: \(url.path)."
        case .hashNotVerified: "The downloaded update has not been independently hash-verified."
        }
    }
}

/// The only trust anchor accepted by this installer. It is read from the current app bundle.
public struct UpdateTrustAnchor: Equatable, Sendable {
    public let teamIdentifier: String

    public init(currentBundle: Bundle = .main) throws {
        guard let value = currentBundle.object(forInfoDictionaryKey: UpdateInstallerConstants.trustAnchorInfoPlistKey) as? String else {
            throw UpdateInstallerError.missingTrustedTeamIdentifier
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UpdateInstallerError.missingTrustedTeamIdentifier }
        guard trimmed.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw UpdateInstallerError.invalidTrustedTeamIdentifier
        }
        teamIdentifier = trimmed
    }

    public static func loadCurrent(bundle: Bundle = .main) throws -> Self {
        try Self(currentBundle: bundle)
    }

    // Internal fixture constructor. Production callers must use the current bundle initializer above.
    init(testTeamIdentifier: String) throws {
        let trimmed = testTeamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UpdateInstallerError.missingTrustedTeamIdentifier }
        guard trimmed.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw UpdateInstallerError.invalidTrustedTeamIdentifier
        }
        teamIdentifier = trimmed
    }
}

/// A fixed-target plan. It carries no operation that can mount, copy, replace, delete, or launch.
public struct UpdateInstallPlan: Equatable, Sendable {
    public let targetURL: URL
    public let expectedBundleIdentifier: String
    public let expectedVersion: String
    public let trustAnchor: UpdateTrustAnchor

    public init(
        expectedVersion: String,
        currentBundle: Bundle = .main,
        targetURL: URL = UpdateInstallerConstants.canonicalTargetURL,
        bundleIdentifier: String = UpdateInstallerConstants.expectedBundleIdentifier
    ) throws {
        guard !targetURL.pathComponents.contains(".."),
              targetURL.standardizedFileURL == UpdateInstallerConstants.canonicalTargetURL else {
            throw UpdateInstallerError.targetOverrideRejected(targetURL)
        }
        guard bundleIdentifier == UpdateInstallerConstants.expectedBundleIdentifier else {
            throw UpdateInstallerError.bundleIdentifierOverrideRejected(bundleIdentifier)
        }
        let version = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw UpdateInstallerError.invalidVersion }
        self.targetURL = UpdateInstallerConstants.canonicalTargetURL
        self.expectedBundleIdentifier = UpdateInstallerConstants.expectedBundleIdentifier
        self.expectedVersion = version
        self.trustAnchor = try UpdateTrustAnchor(currentBundle: currentBundle)
    }

    init(expectedVersion: String, trustAnchor: UpdateTrustAnchor, targetURL: URL = UpdateInstallerConstants.canonicalTargetURL) throws {
        guard !targetURL.pathComponents.contains(".."),
              targetURL.standardizedFileURL == UpdateInstallerConstants.canonicalTargetURL else {
            throw UpdateInstallerError.targetOverrideRejected(targetURL)
        }
        let version = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw UpdateInstallerError.invalidVersion }
        self.targetURL = UpdateInstallerConstants.canonicalTargetURL
        self.expectedBundleIdentifier = UpdateInstallerConstants.expectedBundleIdentifier
        self.expectedVersion = version
        self.trustAnchor = trustAnchor
    }

    public func layout(
        transactionID: UUID,
        applicationSupportURL: URL,
        fileSystem: any UpdateInstallerFileSystem = LocalUpdateInstallerFileSystem()
    ) throws -> UpdateInstallLayout {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        let stagingURL = try policy.stagingURL(for: transactionID)
        let backupURL = try policy.backupURL(for: transactionID)
        let recoveryURL = try policy.recoveryURL(for: transactionID, under: applicationSupportURL)
        return UpdateInstallLayout(
            targetURL: targetURL,
            stagingURL: stagingURL,
            backupURL: backupURL,
            recoveryURL: recoveryURL
        )
    }
}

public struct UpdateInstallLayout: Equatable, Sendable {
    public let targetURL: URL
    public let stagingURL: URL
    public let backupURL: URL
    public let recoveryURL: URL
}

public struct UpdatePathMetadata: Equatable, Sendable {
    public let exists: Bool
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let posixPermissions: UInt16
    public let ownerUserID: UInt32?

    public init(
        exists: Bool,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        posixPermissions: UInt16 = 0,
        ownerUserID: UInt32? = nil
    ) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.posixPermissions = posixPermissions
        self.ownerUserID = ownerUserID
    }
}

public struct UpdateBundleInfo: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let version: String?
    public let architectures: Set<String>

    public init(bundleIdentifier: String?, version: String?, architectures: Set<String> = []) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.architectures = architectures
    }
}

public protocol UpdateInstallerFileSystem {
    func metadata(at url: URL) throws -> UpdatePathMetadata
    func children(of url: URL) throws -> [URL]
    func bundleInfo(at url: URL) throws -> UpdateBundleInfo
}

public final class LocalUpdateInstallerFileSystem: UpdateInstallerFileSystem {
    public init() {}

    public func metadata(at url: URL) throws -> UpdatePathMetadata {
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            // attributesOfItem uses the directory entry itself, allowing dangling symlinks
            // to be rejected instead of silently treated as a missing path.
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return UpdatePathMetadata(exists: false)
        } catch {
            throw error
        }
        let type = attributes[.type] as? FileAttributeType
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        return UpdatePathMetadata(
            exists: true,
            isDirectory: type == .typeDirectory,
            isSymbolicLink: type == .typeSymbolicLink,
            posixPermissions: mode,
            ownerUserID: owner
        )
    }

    public func children(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    public func bundleInfo(at url: URL) throws -> UpdateBundleInfo {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw UpdateInstallerError.missingBundleIdentifier
        }
        let id = info["CFBundleIdentifier"] as? String
        let shortVersion = info["CFBundleShortVersionString"] as? String
        let buildVersion = info["CFBundleVersion"] as? String
        let version = shortVersion ?? buildVersion
        return UpdateBundleInfo(bundleIdentifier: id, version: version)
    }
}

public struct UpdatePathPolicy {
    public let fileSystem: any UpdateInstallerFileSystem

    public init(fileSystem: any UpdateInstallerFileSystem = LocalUpdateInstallerFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func candidateURL(under mountRoot: URL) throws -> URL {
        try validateRoot(mountRoot)
        var candidates: [URL] = []
        try collectCandidates(in: mountRoot, into: &candidates)
        guard candidates.count == 1 else { throw UpdateInstallerError.candidateCount(candidates.count) }
        return candidates[0]
    }

    public func validateCandidateURL(_ candidate: URL, under mountRoot: URL) throws {
        try validateRoot(mountRoot)
        try rejectTraversal(candidate)
        let rootPath = mountRoot.standardizedFileURL.path.hasSuffix("/") ? mountRoot.standardizedFileURL.path : mountRoot.standardizedFileURL.path + "/"
        guard candidate.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw UpdateInstallerError.candidateNotUnderMountRoot(candidate)
        }
        guard candidate.lastPathComponent == "Switchboard.app" else {
            throw UpdateInstallerError.candidateNotUnderMountRoot(candidate)
        }
        try validatePathComponents(candidate, beneath: mountRoot)
        let metadata = try fileSystem.metadata(at: candidate)
        guard metadata.exists else { throw UpdateInstallerError.missingPath(candidate) }
        guard metadata.isDirectory else { throw UpdateInstallerError.notDirectory(candidate) }
        guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(candidate) }
    }

    public func stagingURL(for transactionID: UUID) throws -> URL {
        try siblingURL(named: ".Switchboard.app.update-\(transactionID.uuidString)")
    }

    public func backupURL(for transactionID: UUID) throws -> URL {
        try siblingURL(named: ".Switchboard.app.backup-\(transactionID.uuidString)")
    }

    public func validateStagingURL(_ url: URL) throws {
        try validateSibling(url, prefix: ".Switchboard.app.update-")
    }

    public func validateBackupURL(_ url: URL) throws {
        try validateSibling(url, prefix: ".Switchboard.app.backup-")
    }

    /// Validates the fixed canonical target without requiring it to exist yet.
    public func validateCanonicalTarget() throws {
        let target = UpdateInstallerConstants.canonicalTargetURL
        try rejectTraversal(target)
        if try fileSystem.metadata(at: target).isSymbolicLink {
            throw UpdateInstallerError.symbolicLink(target)
        }
    }

    public func recoveryURL(for transactionID: UUID, under applicationSupportURL: URL) throws -> URL {
        let recoveryRoot = try recoveryRootURL(under: applicationSupportURL)
        let url = recoveryRoot.appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try validateDescendant(url, beneath: applicationSupportURL)
        return url
    }

    /// Returns the one recovery root used by the updater. The root may not exist on
    /// a first launch, but every existing component is checked for traversal and
    /// symbolic links before it is returned.
    public func recoveryRootURL(under applicationSupportURL: URL) throws -> URL {
        try validateApplicationSupport(applicationSupportURL)
        let switchboardRoot = applicationSupportURL
            .appendingPathComponent("Switchboard", isDirectory: true)
        let switchboardMetadata = try fileSystem.metadata(at: switchboardRoot)
        if switchboardMetadata.exists {
            guard switchboardMetadata.isDirectory, !switchboardMetadata.isSymbolicLink else {
                throw UpdateInstallerError.transactionRecordPathInvalid
            }
            try validateOwnerOnly(switchboardRoot, metadata: switchboardMetadata, requireOwner: true)
        }
        let recoveryRoot = switchboardRoot
            .appendingPathComponent(UpdateInstallerConstants.recoveryDirectoryName, isDirectory: true)
        try validateDescendant(recoveryRoot, beneath: applicationSupportURL)
        let metadata = try fileSystem.metadata(at: recoveryRoot)
        if metadata.exists {
            guard metadata.isDirectory, !metadata.isSymbolicLink else {
                throw UpdateInstallerError.transactionRecordPathInvalid
            }
            try validateOwnerOnly(recoveryRoot, metadata: metadata, requireOwner: true)
        }
        return recoveryRoot
    }

    public func validateRecoveryURL(_ url: URL, under applicationSupportURL: URL) throws {
        try validateApplicationSupport(applicationSupportURL)
        try validateDescendant(url, beneath: applicationSupportURL)
    }

    /// Validates a recovered mount point before a detach is attempted. Local
    /// effects call this for paths read from a persisted transaction record.
    public func validateMountRoot(_ url: URL) throws {
        try rejectTraversal(url)
        let standardized = url.standardizedFileURL
        guard standardized.path != "/",
              standardized.path != UpdateInstallerConstants.canonicalTargetURL.path else {
            throw UpdateInstallerError.invalidPath("unsafe mount root")
        }
        let metadata = try fileSystem.metadata(at: standardized)
        guard metadata.exists else { throw UpdateInstallerError.missingPath(standardized) }
        guard metadata.isDirectory else { throw UpdateInstallerError.notDirectory(standardized) }
        guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(standardized) }
        try validatePathComponents(standardized, beneath: standardized.deletingLastPathComponent())
    }

    private func validateRoot(_ root: URL) throws {
        try rejectTraversal(root)
        let metadata = try fileSystem.metadata(at: root)
        guard metadata.exists else { throw UpdateInstallerError.missingPath(root) }
        guard metadata.isDirectory else { throw UpdateInstallerError.notDirectory(root) }
        guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(root) }
    }

    private func collectCandidates(in directory: URL, into candidates: inout [URL]) throws {
        let children = try fileSystem.children(of: directory)
        for child in children {
            try rejectTraversal(child)
            let metadata = try fileSystem.metadata(at: child)
            guard metadata.exists else { continue }
            guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(child) }
            if child.lastPathComponent == "Switchboard.app" {
                guard metadata.isDirectory else { throw UpdateInstallerError.notDirectory(child) }
                candidates.append(child.standardizedFileURL)
            } else if metadata.isDirectory {
                try collectCandidates(in: child, into: &candidates)
            }
        }
    }

    private func siblingURL(named name: String) throws -> URL {
        let url = UpdateInstallerConstants.canonicalTargetURL
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
        let prefix = name.contains(".backup-") ? ".Switchboard.app.backup-" : ".Switchboard.app.update-"
        try validateSibling(url, prefix: prefix)
        return url
    }

    private func validateSibling(_ url: URL, prefix: String) throws {
        try rejectTraversal(url)
        guard url.deletingLastPathComponent().standardizedFileURL == UpdateInstallerConstants.canonicalTargetURL.deletingLastPathComponent().standardizedFileURL else {
            throw UpdateInstallerError.invalidSibling(url)
        }
        guard url.standardizedFileURL != UpdateInstallerConstants.canonicalTargetURL else {
            throw UpdateInstallerError.invalidSibling(url)
        }
        let suffix = String(url.lastPathComponent.dropFirst(prefix.count))
        guard url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: suffix) != nil else {
            throw UpdateInstallerError.invalidSibling(url)
        }
        if try fileSystem.metadata(at: url).isSymbolicLink {
            throw UpdateInstallerError.symbolicLink(url)
        }
    }

    private func validateApplicationSupport(_ url: URL) throws {
        try rejectTraversal(url)
        let metadata = try fileSystem.metadata(at: url)
        guard metadata.exists else { throw UpdateInstallerError.missingPath(url) }
        guard metadata.isDirectory else { throw UpdateInstallerError.notDirectory(url) }
        guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(url) }
        guard metadata.posixPermissions & 0o077 == 0 else {
            throw UpdateInstallerError.applicationSupportPermissions(url, metadata.posixPermissions)
        }
    }

    private func validateOwnerOnly(
        _ url: URL,
        metadata: UpdatePathMetadata,
        requireOwner: Bool
    ) throws {
        guard metadata.posixPermissions & 0o077 == 0 else {
            throw UpdateInstallerError.applicationSupportPermissions(url, metadata.posixPermissions)
        }
        if requireOwner {
            guard let owner = metadata.ownerUserID, owner == UInt32(getuid()) else {
                throw UpdateInstallerError.applicationSupportOwnership(url)
            }
        } else if let owner = metadata.ownerUserID, owner != UInt32(getuid()) {
            throw UpdateInstallerError.applicationSupportOwnership(url)
        }
    }

    private func validateDescendant(_ url: URL, beneath root: URL) throws {
        try rejectTraversal(url)
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw UpdateInstallerError.invalidPath("not beneath Application Support")
        }

        try validatePathComponents(url, beneath: root)
    }

    private func validatePathComponents(_ url: URL, beneath root: URL) throws {
        let relativeComponents = url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
        var current = root.standardizedFileURL
        for component in relativeComponents {
            current.appendPathComponent(component)
            if try fileSystem.metadata(at: current).isSymbolicLink {
                throw UpdateInstallerError.symbolicLink(current)
            }
        }
    }

    private func rejectTraversal(_ url: URL) throws {
        if url.pathComponents.contains("..") {
            throw UpdateInstallerError.pathTraversal(url)
        }
    }
}

public struct UpdateCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var displayString: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public struct UpdateCommandResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public protocol UpdateCommandRunner {
    func run(_ command: UpdateCommand) throws -> UpdateCommandResult
}

public final class LocalUpdateCommandRunner: UpdateCommandRunner {
    public init() {}

    public func run(_ command: UpdateCommand) throws -> UpdateCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw UpdateInstallerError.commandFailed(command.displayString, -1, error.localizedDescription)
        }
        process.waitUntilExit()
        let stdout = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return UpdateCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public struct UpdateCandidateValidation: Equatable, Sendable {
    public let candidateURL: URL
    public let bundleInfo: UpdateBundleInfo
    public let teamIdentifier: String
    public let designatedRequirement: String
    public let architectures: Set<String>
}

public struct UpdateCandidateValidator {
    public let fileSystem: any UpdateInstallerFileSystem
    public let commandRunner: any UpdateCommandRunner

    public init(
        fileSystem: any UpdateInstallerFileSystem = LocalUpdateInstallerFileSystem(),
        commandRunner: any UpdateCommandRunner = LocalUpdateCommandRunner()
    ) {
        self.fileSystem = fileSystem
        self.commandRunner = commandRunner
    }

    public func validate(candidateUnder mountRoot: URL, plan: UpdateInstallPlan) throws -> UpdateCandidateValidation {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        let candidate = try policy.candidateURL(under: mountRoot)
        return try validate(candidateAt: candidate, plan: plan, policy: policy)
    }

    public func validate(candidateAt candidate: URL, plan: UpdateInstallPlan) throws -> UpdateCandidateValidation {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        return try validate(candidateAt: candidate, plan: plan, policy: policy)
    }

    private func validate(candidateAt candidate: URL, plan: UpdateInstallPlan, policy: UpdatePathPolicy) throws -> UpdateCandidateValidation {
        let mountRoot = candidate.deletingLastPathComponent()
        try policy.validateCandidateURL(candidate, under: mountRoot)
        let info = try fileSystem.bundleInfo(at: candidate)
        guard let bundleIdentifier = info.bundleIdentifier else { throw UpdateInstallerError.missingBundleIdentifier }
        guard bundleIdentifier == plan.expectedBundleIdentifier else {
            throw UpdateInstallerError.bundleIdentifierMismatch(expected: plan.expectedBundleIdentifier, actual: info.bundleIdentifier)
        }
        guard let version = info.version else { throw UpdateInstallerError.missingBundleVersion }
        guard version == plan.expectedVersion else {
            throw UpdateInstallerError.bundleVersionMismatch(expected: plan.expectedVersion, actual: info.version)
        }

        let candidateExecutable = candidate
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(UpdateInstallerConstants.expectedExecutableName)
        let architectureResult = try run(UpdateCommand(
            executable: "/usr/bin/lipo",
            arguments: ["-archs", candidateExecutable.path]
        ))
        guard architectureResult.status == 0 else {
            throw UpdateInstallerError.commandFailed(
                "/usr/bin/lipo -archs \(candidateExecutable.path)",
                architectureResult.status,
                architectureResult.combinedOutput
            )
        }
        var architectures = info.architectures
        architectures.formUnion(Self.parseArchitectures(architectureResult.stdout))
        guard architectures.contains("arm64") else { throw UpdateInstallerError.missingArm64 }

        let signature = try run(UpdateCommand(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", candidate.path]))
        guard signature.status == 0 else {
            throw UpdateInstallerError.codeSignatureRejected(signature.status, signature.combinedOutput)
        }

        let details = try run(UpdateCommand(executable: "/usr/bin/codesign", arguments: ["--display", "--verbose=4", candidate.path]))
        guard details.status == 0 else {
            throw UpdateInstallerError.commandFailed(
                "/usr/bin/codesign --display --verbose=4 \(candidate.path)",
                details.status,
                details.combinedOutput
            )
        }
        let teamIdentifier = Self.parseTeamIdentifier(details.combinedOutput)
        guard let teamIdentifier else { throw UpdateInstallerError.teamIdentifierMissing }
        guard teamIdentifier == plan.trustAnchor.teamIdentifier else {
            throw UpdateInstallerError.teamIdentifierMismatch(expected: plan.trustAnchor.teamIdentifier, actual: teamIdentifier)
        }

        let requirement = try run(UpdateCommand(executable: "/usr/bin/codesign", arguments: ["--display", "--requirements", "-", candidate.path]))
        guard requirement.status == 0 else {
            throw UpdateInstallerError.commandFailed(
                "/usr/bin/codesign --display --requirements - \(candidate.path)",
                requirement.status,
                requirement.combinedOutput
            )
        }
        let designatedRequirement = requirement.combinedOutput
        guard Self.isAppleDeveloperIDApplicationRequirement(designatedRequirement) else {
            throw UpdateInstallerError.designatedRequirementRejected
        }

        let gatekeeper = try run(UpdateCommand(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "--verbose=4", candidate.path]))
        guard gatekeeper.status == 0 else {
            throw UpdateInstallerError.gatekeeperRejected(gatekeeper.status, gatekeeper.combinedOutput)
        }

        return UpdateCandidateValidation(
            candidateURL: candidate.standardizedFileURL,
            bundleInfo: info,
            teamIdentifier: teamIdentifier,
            designatedRequirement: designatedRequirement,
            architectures: architectures
        )
    }

    private func run(_ command: UpdateCommand) throws -> UpdateCommandResult {
        try commandRunner.run(command)
    }

    static func parseArchitectures(_ output: String) -> Set<String> {
        Set(output.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }.map(String.init))
    }

    static func parseTeamIdentifier(_ output: String) -> String? {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let text = String(line)
            guard let range = text.range(of: "TeamIdentifier=") else { continue }
            let value = text[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            if let value, !value.isEmpty { return String(value) }
        }
        return nil
    }

    static func isAppleDeveloperIDApplicationRequirement(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("anchor apple generic") &&
            lowercased.contains("1.2.840.113635.100.6.1.13")
    }
}

public struct ParentIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let resolvedExecutableURL: URL
    public let startTime: Date

    public init(pid: Int32, executableURL: URL, startTime: Date) {
        self.pid = pid
        self.resolvedExecutableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        self.startTime = startTime
    }

    public func matches(pid: Int32, executableURL: URL, startTime: Date) -> Bool {
        self == ParentIdentity(pid: pid, executableURL: executableURL, startTime: startTime)
    }

    public func matches(_ other: ParentIdentity) -> Bool {
        self == other
    }
}

public enum UpdateInstallState: String, CaseIterable, Codable, Sendable {
    case downloaded
    case hashVerified
    case mounted
    case candidateVerified
    case staged
    case recoveryVerified
    case replacing
    case installedVerified
    case completed
    case rollingBack
    case rolledBack
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .rolledBack, .failed: true
        default: false
        }
    }

    /// An interrupted transaction is any non-terminal record. Recovery is only needed once
    /// mounted state or replacement-related state could have changed external state.
    public var isInterrupted: Bool { !isTerminal }

    public var needsRecoveryAfterInterruption: Bool {
        switch self {
        case .mounted, .candidateVerified, .staged, .recoveryVerified,
             .replacing, .installedVerified, .rollingBack:
            true
        case .downloaded, .hashVerified, .completed, .rolledBack, .failed:
            false
        }
    }

    public var isRecoveryBoundary: Bool {
        needsRecoveryAfterInterruption
    }

    public func canTransition(to next: UpdateInstallState) -> Bool {
        switch (self, next) {
        case (.downloaded, .hashVerified),
             (.hashVerified, .mounted),
             (.mounted, .candidateVerified),
             (.candidateVerified, .staged),
             (.staged, .recoveryVerified),
             (.recoveryVerified, .replacing),
             (.replacing, .installedVerified),
             (.installedVerified, .completed),
             (.rollingBack, .rolledBack):
            true
        case (.mounted, .rollingBack),
             (.candidateVerified, .rollingBack),
             (.staged, .rollingBack),
             (.recoveryVerified, .rollingBack),
             (.replacing, .rollingBack),
             (.installedVerified, .rollingBack):
            true
        case (.downloaded, .failed),
             (.hashVerified, .failed),
             (.mounted, .failed),
             (.candidateVerified, .failed),
             (.staged, .failed),
             (.recoveryVerified, .failed),
             (.replacing, .failed),
             (.installedVerified, .failed),
             (.rollingBack, .failed):
            true
        default:
            false
        }
    }
}

public struct UpdateInstallEvent: Codable, Equatable, Sendable {
    public let state: UpdateInstallState
    public let at: Date
    public let note: String

    public init(state: UpdateInstallState, at: Date, note: String) {
        self.state = state
        self.at = at
        self.note = note
    }
}

/// The side effect that the helper is about to perform. It is persisted alongside the
/// next state so a crash leaves an explicit recovery decision rather than an ambiguous gap.
public struct UpdateInstallIntent: Codable, Equatable, Sendable {
    public let state: UpdateInstallState
    public let operation: String
    public let at: Date

    public init(state: UpdateInstallState, operation: String, at: Date) {
        self.state = state
        self.operation = operation
        self.at = at
    }
}

public enum UpdateInterruption: Equatable, Sendable {
    case none
    case unfinished(UpdateInstallState)
    case parentIdentityChanged
}

public struct UpdateInstallRecord: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let parentIdentity: ParentIdentity
    public private(set) var state: UpdateInstallState
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var events: [UpdateInstallEvent]
    public private(set) var pendingIntent: UpdateInstallIntent?
    /// The mounted image path is persisted immediately after a successful mount so
    /// a later helper launch can detach an image left behind by a crashed helper.
    public private(set) var mountedRoot: URL?

    public init(
        transactionID: UUID = UUID(),
        parentIdentity: ParentIdentity,
        now: Date = Date()
    ) {
        self.transactionID = transactionID
        self.parentIdentity = parentIdentity
        self.state = .downloaded
        self.createdAt = now
        self.updatedAt = now
        self.events = [UpdateInstallEvent(state: .downloaded, at: now, note: "downloaded")]
        self.pendingIntent = nil
        self.mountedRoot = nil
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID
        case parentIdentity
        case state
        case createdAt
        case updatedAt
        case events
        case pendingIntent
        case mountedRoot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionID = try container.decode(UUID.self, forKey: .transactionID)
        parentIdentity = try container.decode(ParentIdentity.self, forKey: .parentIdentity)
        state = try container.decode(UpdateInstallState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        events = try container.decode([UpdateInstallEvent].self, forKey: .events)
        pendingIntent = try container.decodeIfPresent(UpdateInstallIntent.self, forKey: .pendingIntent)
        // Records written before cross-launch mount recovery did not contain this key.
        mountedRoot = try container.decodeIfPresent(URL.self, forKey: .mountedRoot)
    }

    public mutating func transition(to next: UpdateInstallState, note: String, at: Date = Date()) throws {
        guard state.canTransition(to: next) else {
            throw UpdateInstallerError.illegalTransition(from: state, to: next)
        }
        state = next
        updatedAt = at
        events.append(UpdateInstallEvent(state: next, at: at, note: note))
    }

    /// Records a legal next state and the side effect that must follow it.
    public mutating func prepareIntent(
        next state: UpdateInstallState,
        operation: String,
        at: Date = Date()
    ) throws {
        try transition(to: state, note: "intent:\(operation)", at: at)
        pendingIntent = UpdateInstallIntent(state: state, operation: operation, at: at)
    }

    /// Records another side effect under the already-entered state (for example unmount,
    /// which has no separate published state) before it is attempted.
    public mutating func prepareIntent(
        operation: String,
        at: Date = Date()
    ) {
        pendingIntent = UpdateInstallIntent(state: state, operation: operation, at: at)
        updatedAt = at
    }

    public mutating func clearIntent(at: Date = Date()) {
        pendingIntent = nil
        updatedAt = at
    }

    public mutating func setMountedRoot(_ root: URL, at: Date = Date()) {
        mountedRoot = root.standardizedFileURL
        updatedAt = at
    }

    public mutating func clearMountedRoot(at: Date = Date()) {
        mountedRoot = nil
        updatedAt = at
    }

    public func interruption(observedParent: ParentIdentity? = nil) -> UpdateInterruption {
        if let observedParent, !parentIdentity.matches(observedParent) {
            return .parentIdentityChanged
        }
        return state.isInterrupted ? .unfinished(state) : .none
    }

    public func verifyParent(_ observedParent: ParentIdentity) throws {
        guard parentIdentity.matches(observedParent) else {
            throw UpdateInstallerError.parentIdentityMismatch
        }
    }
}

public struct UpdateMount: Equatable, Sendable {
    public let mountRoot: URL

    public init(mountRoot: URL) {
        self.mountRoot = mountRoot.standardizedFileURL
    }
}

/// Every method represents one real side effect. The transaction coordinator persists its
/// next state and intent before calling any method here.
public protocol UpdateInstallerEffects {
    func mountReadOnly(imageURL: URL) throws -> UpdateMount
    func stage(candidateURL: URL, stagingURL: URL) throws
    func createRecoveryBackup(targetURL: URL, backupURL: URL) throws
    func atomicReplace(stagingURL: URL, targetURL: URL) throws
    func verifyInstalled(targetURL: URL, plan: UpdateInstallPlan) throws
    func rollback(targetURL: URL, backupURL: URL) throws
    func unmount(mountRoot: URL) throws
}

/// The persisted record contract is injectable so tests never touch Application Support.
public protocol UpdateInstallRecordStore {
    func save(_ record: UpdateInstallRecord) throws
    func load() throws -> UpdateInstallRecord?
}

public typealias UpdateInstallerOperationProvider = UpdateInstallerEffects
public typealias UpdateInstallerPersistence = UpdateInstallRecordStore

/// Owner-only JSON persistence used by the separate helper process.
public final class OwnerOnlyUpdateInstallRecordStore: UpdateInstallRecordStore {
    public let recordURL: URL
    private let applicationSupportURL: URL
    private let fileSystem: any UpdateInstallerFileSystem

    public init(
        layout: UpdateInstallLayout,
        applicationSupportURL: URL,
        fileSystem: any UpdateInstallerFileSystem = LocalUpdateInstallerFileSystem()
    ) throws {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateRecoveryURL(layout.recoveryURL, under: applicationSupportURL)
        self.recordURL = layout.recoveryURL.appendingPathComponent("transaction.json")
        self.applicationSupportURL = applicationSupportURL
        self.fileSystem = fileSystem
    }

    public func save(_ record: UpdateInstallRecord) throws {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateRecoveryURL(recordURL, under: applicationSupportURL)
        let existing = try fileSystem.metadata(at: recordURL)
        if existing.exists {
            guard !existing.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(recordURL) }
            guard existing.posixPermissions & 0o077 == 0 else {
                throw UpdateInstallerError.applicationSupportPermissions(recordURL, existing.posixPermissions)
            }
        }
        let directory = recordURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let directoryMetadata = try fileSystem.metadata(at: directory)
        guard directoryMetadata.exists,
              directoryMetadata.isDirectory,
              !directoryMetadata.isSymbolicLink,
              directoryMetadata.posixPermissions & 0o077 == 0,
              directoryMetadata.ownerUserID == UInt32(getuid()) else {
            throw UpdateInstallerError.transactionRecordPathInvalid
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: recordURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    public func load() throws -> UpdateInstallRecord? {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateRecoveryURL(recordURL, under: applicationSupportURL)
        let metadata = try fileSystem.metadata(at: recordURL)
        guard metadata.exists else { return nil }
        guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(recordURL) }
        guard metadata.posixPermissions & 0o077 == 0 else {
            throw UpdateInstallerError.applicationSupportPermissions(recordURL, metadata.posixPermissions)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UpdateInstallRecord.self, from: Data(contentsOf: recordURL))
    }
}

public typealias UpdateInstallRecordStoreFactory = (
    UpdateInstallLayout,
    URL,
    any UpdateInstallerFileSystem
) throws -> any UpdateInstallRecordStore

/// Creates or repairs only Switchboard's own recovery directories. Existing
/// links, foreign ownership, and non-directories remain hard failures.
public enum UpdateRecoveryDirectory {
    public static func prepare(
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try validateOwnerOnlyDirectory(applicationSupportURL, fileManager: fileManager)
        let switchboard = applicationSupportURL.appendingPathComponent("Switchboard", isDirectory: true)
        let recovery = switchboard.appendingPathComponent(
            UpdateInstallerConstants.recoveryDirectoryName,
            isDirectory: true
        )
        try ensureOwnerOnlyDirectory(switchboard, fileManager: fileManager)
        try ensureOwnerOnlyDirectory(recovery, fileManager: fileManager)
    }

    private static func ensureOwnerOnlyDirectory(_ url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw UpdateInstallerError.transactionRecordPathInvalid
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try validateOwnerOnlyDirectory(url, fileManager: fileManager)
    }

    private static func validateOwnerOnlyDirectory(_ url: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0 else {
            throw UpdateInstallerError.transactionRecordPathInvalid
        }
    }
}

/// A recovered transaction and the canonical layout reconstructed from its UUID
/// directory. The layout never comes from the persisted JSON record.
public struct UpdateInstallRecoveryEntry: Equatable, Sendable {
    public let layout: UpdateInstallLayout
    public let record: UpdateInstallRecord

    public init(layout: UpdateInstallLayout, record: UpdateInstallRecord) {
        self.layout = layout
        self.record = record
    }
}

/// Discovers owner-only transaction records and resumes their safe cleanup. This
/// coordinator deliberately never removes a record or a recovery backup.
public final class UpdateInstallRecovery {
    private let applicationSupportURL: URL
    private let fileSystem: any UpdateInstallerFileSystem
    private let effects: any UpdateInstallerEffects
    private let storeFactory: UpdateInstallRecordStoreFactory

    public init(
        applicationSupportURL: URL,
        effects: any UpdateInstallerEffects,
        fileSystem: any UpdateInstallerFileSystem = LocalUpdateInstallerFileSystem(),
        storeFactory: @escaping UpdateInstallRecordStoreFactory = { layout, applicationSupportURL, fileSystem in
            try OwnerOnlyUpdateInstallRecordStore(
                layout: layout,
                applicationSupportURL: applicationSupportURL,
                fileSystem: fileSystem
            )
        }
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.effects = effects
        self.fileSystem = fileSystem
        self.storeFactory = storeFactory
    }

    /// Returns only direct children with a canonical, uppercase UUID name and an
    /// owner-only transaction record. Any ambiguity fails closed.
    public func discover() throws -> [UpdateInstallRecoveryEntry] {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        let root = try policy.recoveryRootURL(under: applicationSupportURL)
        let rootMetadata = try fileSystem.metadata(at: root)
        guard rootMetadata.exists else { return [] }
        guard rootMetadata.isDirectory, !rootMetadata.isSymbolicLink else {
            throw UpdateInstallerError.transactionRecordPathInvalid
        }
        try validateOwnerOnly(root, metadata: rootMetadata)

        let children = try fileSystem.children(of: root).sorted { $0.path < $1.path }
        var discovered: [UpdateInstallRecoveryEntry] = []
        for child in children {
            try validateTransactionDirectory(child, under: root)
            guard let transactionID = UUID(uuidString: child.lastPathComponent),
                  transactionID.uuidString == child.lastPathComponent else {
                throw UpdateInstallerError.transactionRecordPathInvalid
            }

            let layout = UpdateInstallLayout(
                targetURL: UpdateInstallerConstants.canonicalTargetURL,
                stagingURL: try policy.stagingURL(for: transactionID),
                backupURL: try policy.backupURL(for: transactionID),
                recoveryURL: child.standardizedFileURL
            )
            let recordURL = child.appendingPathComponent("transaction.json")
            let entries = try fileSystem.children(of: child)
            guard entries.count == 1,
                  entries.first?.lastPathComponent == recordURL.lastPathComponent else {
                throw UpdateInstallerError.transactionRecordPathInvalid
            }
            let store = try storeFactory(layout, applicationSupportURL, fileSystem)
            guard let record = try store.load() else {
                throw UpdateInstallerError.transactionRecordPathInvalid
            }
            guard record.transactionID == transactionID else {
                throw UpdateInstallerError.transactionIdentityMismatch
            }
            guard !record.parentIdentity.resolvedExecutableURL.pathComponents.contains(".."),
                  record.parentIdentity.resolvedExecutableURL == UpdateInstallerConstants.canonicalExecutableURL.standardizedFileURL else {
                throw UpdateInstallerError.invalidParentExecutable(record.parentIdentity.resolvedExecutableURL)
            }
            discovered.append(UpdateInstallRecoveryEntry(layout: layout, record: record))
        }
        return discovered
    }

    /// Completes cleanup for completed records and rolls back every transaction
    /// that could have changed the canonical target. Records and backups remain
    /// available as an audit and manual-recovery trail.
    @discardableResult
    public func resume() throws -> [UpdateInstallRecord] {
        let entries = try discover()
        var resumed: [UpdateInstallRecord] = []
        for entry in entries {
            let store = try storeFactory(entry.layout, applicationSupportURL, fileSystem)
            var record = entry.record
            switch record.state {
            case .completed:
                try completeCleanup(record: &record, store: store)
            case .failed, .rolledBack:
                // A failed transaction can still have a mount left behind if the
                // original helper crashed during its failure path.
                if record.mountedRoot != nil {
                    try completeCleanup(record: &record, store: store)
                }
            case .downloaded, .hashVerified:
                // No external update effect has been entered yet. Make this
                // terminal so it cannot block every future update forever.
                try record.transition(to: .failed, note: "interrupted before external change")
                record.clearIntent()
                try store.save(record)
            case .mounted, .candidateVerified, .staged:
                try recoverBeforeBackup(record: &record, store: store)
            case .recoveryVerified, .replacing, .installedVerified, .rollingBack:
                try rollback(record: &record, layout: entry.layout, store: store)
            }
            resumed.append(record)
        }
        return resumed
    }

    private func validateTransactionDirectory(_ url: URL, under root: URL) throws {
        guard !url.pathComponents.contains(".."),
              url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw UpdateInstallerError.transactionRecordPathInvalid
        }
        let metadata = try fileSystem.metadata(at: url)
        guard metadata.exists else { throw UpdateInstallerError.transactionRecordPathInvalid }
        guard metadata.isDirectory else { throw UpdateInstallerError.transactionRecordPathInvalid }
        guard !metadata.isSymbolicLink else { throw UpdateInstallerError.symbolicLink(url) }
        try validateOwnerOnly(url, metadata: metadata)
    }

    private func validateOwnerOnly(_ url: URL, metadata: UpdatePathMetadata) throws {
        guard metadata.posixPermissions & 0o077 == 0 else {
            throw UpdateInstallerError.applicationSupportPermissions(url, metadata.posixPermissions)
        }
        guard let owner = metadata.ownerUserID, owner == UInt32(getuid()) else {
            throw UpdateInstallerError.applicationSupportOwnership(url)
        }
    }

    private func completeCleanup(
        record: inout UpdateInstallRecord,
        store: any UpdateInstallRecordStore
    ) throws {
        if let mountedRoot = record.mountedRoot {
            record.prepareIntent(operation: "unmount-read-only")
            try store.save(record)
            try effects.unmount(mountRoot: mountedRoot)
            record.clearMountedRoot()
        }
        if record.pendingIntent != nil {
            record.clearIntent()
        }
        try store.save(record)
    }

    private func recoverBeforeBackup(
        record: inout UpdateInstallRecord,
        store: any UpdateInstallRecordStore
    ) throws {
        guard record.mountedRoot != nil else {
            throw UpdateInstallerError.mountedRootUnavailable
        }
        try record.prepareIntent(next: .rollingBack, operation: "rollback")
        try store.save(record)
        guard let mountedRoot = record.mountedRoot else {
            throw UpdateInstallerError.mountedRootUnavailable
        }
        record.prepareIntent(operation: "unmount-read-only")
        try store.save(record)
        try effects.unmount(mountRoot: mountedRoot)
        record.clearMountedRoot()
        try record.transition(to: .failed, note: "interrupted before recovery backup")
        record.clearIntent()
        try store.save(record)
    }

    private func rollback(
        record: inout UpdateInstallRecord,
        layout: UpdateInstallLayout,
        store: any UpdateInstallRecordStore
    ) throws {
        if record.state == .rollingBack {
            record.prepareIntent(operation: "rollback")
        } else {
            try record.prepareIntent(next: .rollingBack, operation: "rollback")
        }
        try store.save(record)

        if let mountedRoot = record.mountedRoot {
            record.prepareIntent(operation: "unmount-read-only")
            try store.save(record)
            try effects.unmount(mountRoot: mountedRoot)
            record.clearMountedRoot()
            try store.save(record)
        }

        record.prepareIntent(operation: "rollback")
        try store.save(record)
        try effects.rollback(targetURL: UpdateInstallerConstants.canonicalTargetURL, backupURL: layout.backupURL)
        try record.transition(to: .rolledBack, note: "cross-launch rollback completed")
        record.clearMountedRoot()
        record.clearIntent()
        try store.save(record)
    }
}

public typealias UpdateInstallRecoveryCoordinator = UpdateInstallRecovery

/// A real macOS effect implementation. Tests inject a fake instead, so no test mounts or
/// modifies `/Applications`.
public final class LocalUpdateInstallerEffects: UpdateInstallerEffects {
    private let fileSystem: any UpdateInstallerFileSystem
    private let commandRunner: any UpdateCommandRunner
    private let validator: UpdateCandidateValidator

    public init(
        fileSystem: any UpdateInstallerFileSystem = LocalUpdateInstallerFileSystem(),
        commandRunner: any UpdateCommandRunner = LocalUpdateCommandRunner()
    ) {
        self.fileSystem = fileSystem
        self.commandRunner = commandRunner
        self.validator = UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: commandRunner)
    }

    public func mountReadOnly(imageURL: URL) throws -> UpdateMount {
        let result = try commandRunner.run(UpdateCommand(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", imageURL.path, "-readonly", "-nobrowse", "-plist"]
        ))
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateInstallerError.mountOutputInvalid
        }
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
        guard mountPoints.count == 1, let path = mountPoints.first else {
            throw UpdateInstallerError.mountOutputInvalid
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        _ = try policy.candidateURL(under: root)
        return UpdateMount(mountRoot: root)
    }

    public func stage(candidateURL: URL, stagingURL: URL) throws {
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateCandidateURL(candidateURL, under: candidateURL.deletingLastPathComponent())
        try policy.validateStagingURL(stagingURL)
        guard !(try fileSystem.metadata(at: stagingURL)).exists else {
            throw UpdateInstallerError.invalidSibling(stagingURL)
        }
        try FileManager.default.copyItem(at: candidateURL, to: stagingURL)
    }

    public func createRecoveryBackup(targetURL: URL, backupURL: URL) throws {
        try validateCanonicalTargetURL(targetURL)
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateCanonicalTarget()
        try policy.validateBackupURL(backupURL)
        let targetMetadata = try fileSystem.metadata(at: targetURL)
        guard targetMetadata.exists, targetMetadata.isDirectory, !targetMetadata.isSymbolicLink else {
            throw UpdateInstallerError.missingPath(targetURL)
        }
        guard !(try fileSystem.metadata(at: backupURL)).exists else {
            throw UpdateInstallerError.invalidSibling(backupURL)
        }
        try FileManager.default.copyItem(at: targetURL, to: backupURL)
    }

    public func atomicReplace(stagingURL: URL, targetURL: URL) throws {
        try validateCanonicalTargetURL(targetURL)
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateStagingURL(stagingURL)
        try policy.validateCanonicalTarget()
        _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: stagingURL, backupItemName: nil, options: [])
    }

    public func verifyInstalled(targetURL: URL, plan: UpdateInstallPlan) throws {
        try validateCanonicalTargetURL(targetURL)
        _ = try validator.validate(candidateAt: targetURL, plan: plan)
    }

    public func rollback(targetURL: URL, backupURL: URL) throws {
        try validateCanonicalTargetURL(targetURL)
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        try policy.validateBackupURL(backupURL)
        guard (try fileSystem.metadata(at: backupURL)).exists else {
            throw UpdateInstallerError.rollbackUnavailable
        }
        if try fileSystem.metadata(at: targetURL).isSymbolicLink {
            throw UpdateInstallerError.symbolicLink(targetURL)
        }
        if (try fileSystem.metadata(at: targetURL)).exists {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: backupURL, backupItemName: nil, options: [])
        } else {
            try FileManager.default.moveItem(at: backupURL, to: targetURL)
        }
    }

    public func unmount(mountRoot: URL) throws {
        try UpdatePathPolicy(fileSystem: fileSystem).validateMountRoot(mountRoot)
        let result = try commandRunner.run(UpdateCommand(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountRoot.path]
        ))
        guard result.status == 0 else {
            throw UpdateInstallerError.commandFailed(
                "/usr/bin/hdiutil detach \(mountRoot.path)",
                result.status,
                result.combinedOutput
            )
        }
    }

    private func validateCanonicalTargetURL(_ url: URL) throws {
        guard !url.pathComponents.contains(".."),
              url.standardizedFileURL == UpdateInstallerConstants.canonicalTargetURL else {
            throw UpdateInstallerError.targetOverrideRejected(url)
        }
    }
}

/// Coordinates a full update with intent-first persistence and fail-closed rollback.
public final class UpdateInstallerTransaction {
    private let effects: any UpdateInstallerEffects
    private let store: any UpdateInstallRecordStore
    private let validator: UpdateCandidateValidator

    public init(
        effects: any UpdateInstallerEffects,
        store: any UpdateInstallRecordStore,
        validator: UpdateCandidateValidator
    ) {
        self.effects = effects
        self.store = store
        self.validator = validator
    }

    @discardableResult
    public func execute(
        plan: UpdateInstallPlan,
        imageURL: URL,
        layout: UpdateInstallLayout,
        parentIdentity: ParentIdentity,
        existingRecord: UpdateInstallRecord? = nil,
        hashVerified: Bool = false
    ) throws -> UpdateInstallRecord {
        guard !layout.targetURL.pathComponents.contains(".."),
              layout.targetURL.standardizedFileURL == plan.targetURL.standardizedFileURL else {
            throw UpdateInstallerError.targetOverrideRejected(layout.targetURL)
        }
        guard !parentIdentity.resolvedExecutableURL.pathComponents.contains(".."),
              parentIdentity.resolvedExecutableURL == UpdateInstallerConstants.canonicalExecutableURL.standardizedFileURL else {
            throw UpdateInstallerError.invalidParentExecutable(parentIdentity.resolvedExecutableURL)
        }
        guard let layoutTransactionID = UUID(uuidString: layout.recoveryURL.lastPathComponent) else {
            throw UpdateInstallerError.transactionIdentityMismatch
        }
        var record = existingRecord ?? UpdateInstallRecord(
            transactionID: layoutTransactionID,
            parentIdentity: parentIdentity
        )
        guard record.transactionID == layoutTransactionID else {
            throw UpdateInstallerError.transactionIdentityMismatch
        }
        try record.verifyParent(parentIdentity)
        try persist(record)
        var mountedRoot: URL?

        do {
            if record.state == .downloaded {
                guard hashVerified else { throw UpdateInstallerError.hashNotVerified }
                try record.transition(to: .hashVerified, note: "hash verified")
                record.clearIntent()
                try persist(record)
            }
            guard record.state == .hashVerified else {
                throw UpdateInstallerError.illegalTransition(from: record.state, to: .mounted)
            }

            try record.prepareIntent(next: .mounted, operation: "mount-read-only")
            try persist(record)
            let mount = try effects.mountReadOnly(imageURL: imageURL)
            mountedRoot = mount.mountRoot
            record.setMountedRoot(mount.mountRoot)
            try persist(record)

            try record.prepareIntent(next: .candidateVerified, operation: "validate-candidate")
            try persist(record)
            let candidate = try validator.validate(candidateUnder: mount.mountRoot, plan: plan)
            record.clearIntent()
            try persist(record)

            try record.prepareIntent(next: .staged, operation: "stage-candidate")
            try persist(record)
            try effects.stage(candidateURL: candidate.candidateURL, stagingURL: layout.stagingURL)

            try record.prepareIntent(next: .recoveryVerified, operation: "create-exact-recovery-backup")
            try persist(record)
            try effects.createRecoveryBackup(targetURL: layout.targetURL, backupURL: layout.backupURL)

            try record.prepareIntent(next: .replacing, operation: "unmount-read-only")
            try persist(record)
            try effects.unmount(mountRoot: mount.mountRoot)
            mountedRoot = nil
            record.clearMountedRoot()
            record.prepareIntent(operation: "atomic-replace")
            try persist(record)
            try effects.atomicReplace(stagingURL: layout.stagingURL, targetURL: layout.targetURL)

            try record.prepareIntent(next: .installedVerified, operation: "verify-installed")
            try persist(record)
            try effects.verifyInstalled(targetURL: layout.targetURL, plan: plan)

            try record.transition(to: .completed, note: "update completed")
            record.clearIntent()
            try persist(record)
            return record
        } catch {
            let _ = try recover(
                after: error,
                record: &record,
                layout: layout,
                mountedRoot: mountedRoot ?? record.mountedRoot
            )
            throw error
        }
    }

    private func persist(_ record: UpdateInstallRecord) throws {
        try store.save(record)
    }

    private func recover(
        after originalError: Error,
        record: inout UpdateInstallRecord,
        layout: UpdateInstallLayout,
        mountedRoot: URL?
    ) throws -> UpdateInstallRecord {
        if [.mounted, .candidateVerified, .staged].contains(record.state) {
            do {
                try record.prepareIntent(next: .rollingBack, operation: "pre-replacement-cleanup")
                try persist(record)
                if let mountedRoot {
                    record.prepareIntent(operation: "unmount-read-only")
                    try persist(record)
                    try effects.unmount(mountRoot: mountedRoot)
                    record.clearMountedRoot()
                }
                try record.transition(to: .rolledBack, note: "pre-replacement cleanup completed")
                record.clearIntent()
                try persist(record)
            } catch {
                if record.state.canTransition(to: .failed) {
                    try? record.transition(to: .failed, note: "pre-replacement cleanup failed")
                    record.clearIntent()
                    try? persist(record)
                }
            }
            throw originalError
        }
        guard record.state.canTransition(to: .rollingBack) else {
            if record.state.canTransition(to: .failed) {
                try record.transition(to: .failed, note: "update failed")
                record.clearIntent()
                try? persist(record)
            }
            throw originalError
        }

        do {
            if record.state == .rollingBack {
                record.prepareIntent(operation: "rollback")
            } else {
                try record.prepareIntent(next: .rollingBack, operation: "rollback")
            }
            try persist(record)
            if let mountedRoot {
                record.prepareIntent(operation: "unmount-read-only")
                try persist(record)
                try effects.unmount(mountRoot: mountedRoot)
                record.clearMountedRoot()
                try persist(record)
            }
            record.prepareIntent(operation: "rollback")
            try persist(record)
            try effects.rollback(targetURL: layout.targetURL, backupURL: layout.backupURL)
            try record.transition(to: .rolledBack, note: "rollback completed")
            record.clearMountedRoot()
            record.clearIntent()
            try persist(record)
        } catch {
            if record.state.canTransition(to: .failed) {
                try? record.transition(to: .failed, note: "rollback failed")
                record.clearIntent()
                try? persist(record)
            }
        }
        throw originalError
    }
}

public typealias UpdateInstaller = UpdateInstallerTransaction
