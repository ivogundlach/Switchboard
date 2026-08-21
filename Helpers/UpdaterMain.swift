import Darwin
import Foundation

@main
enum SwitchboardUpdaterMain {
    static func main() {
        do {
            let request = try UpdateHelperRequest(arguments: CommandLine.arguments)
            let parent = try ProcessIdentityReader.identity(pid: request.parentPID)
            guard parent.resolvedExecutableURL == UpdateInstallerConstants.canonicalExecutableURL.standardizedFileURL else {
                throw UpdateInstallerError.invalidParentExecutable(parent.resolvedExecutableURL)
            }
            try waitForParentExit(parent)

            let fileManager = FileManager.default
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            try fileManager.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: applicationSupport.path
            )
            try request.validateImage(under: applicationSupport)

            guard let currentBundle = Bundle(url: UpdateInstallerConstants.canonicalTargetURL) else {
                throw UpdateInstallerError.missingPath(UpdateInstallerConstants.canonicalTargetURL)
            }
            let plan = try UpdateInstallPlan(
                expectedVersion: request.version,
                currentBundle: currentBundle
            )
            let runner = LocalUpdateCommandRunner()
            let fileSystem = LocalUpdateInstallerFileSystem()
            let effects = LocalUpdateInstallerEffects(fileSystem: fileSystem, commandRunner: runner)
            try UpdateRecoveryDirectory.prepare(applicationSupportURL: applicationSupport)
            // Resolve every prior transaction before allocating a new UUID or
            // creating a new record. A malformed or failed recovery stops the
            // helper here, leaving the next launch to retry safely.
            let recovery = UpdateInstallRecovery(
                applicationSupportURL: applicationSupport,
                effects: effects,
                fileSystem: fileSystem
            )
            try recovery.resume()

            let transactionID = UUID()
            let layout = try plan.layout(
                transactionID: transactionID,
                applicationSupportURL: applicationSupport
            )
            let store = try OwnerOnlyUpdateInstallRecordStore(
                layout: layout,
                applicationSupportURL: applicationSupport
            )
            let transaction = UpdateInstallerTransaction(
                effects: effects,
                store: store,
                validator: UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: runner)
            )
            _ = try transaction.execute(
                plan: plan,
                imageURL: request.imageURL,
                layout: layout,
                parentIdentity: parent,
                hashVerified: true
            )
            print("Switchboard update installed. It will take effect the next time Switchboard starts.")
        } catch {
            fputs("Switchboard updater failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func waitForParentExit(_ expected: ParentIdentity) throws {
        let deadline = Date().addingTimeInterval(30)
        while kill(expected.pid, 0) == 0 {
            guard Date() < deadline else { throw UpdateHelperError.parentDidNotExit }
            let observed = try ProcessIdentityReader.identity(pid: expected.pid)
            guard observed.matches(expected) else { throw UpdateInstallerError.parentIdentityMismatch }
            usleep(100_000)
        }
    }
}

private struct UpdateHelperRequest {
    let imageURL: URL
    let version: String
    let parentPID: Int32

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count,
                  ["--image", "--version", "--parent-pid"].contains(arguments[index]),
                  values[arguments[index]] == nil else {
                throw UpdateHelperError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard values.count == 3,
              let image = values["--image"],
              let version = values["--version"],
              let parentText = values["--parent-pid"],
              let parentPID = Int32(parentText),
              parentPID > 1,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$", options: .regularExpression) != nil else {
            throw UpdateHelperError.invalidArguments
        }
        self.imageURL = URL(fileURLWithPath: image).standardizedFileURL
        self.version = version
        self.parentPID = parentPID
    }

    func validateImage(under applicationSupport: URL) throws {
        let updates = applicationSupport
            .appending(path: "Switchboard/Updates", directoryHint: .isDirectory)
            .standardizedFileURL
        let prefix = updates.path + "/"
        guard !imageURL.pathComponents.contains(".."),
              imageURL.path.hasPrefix(prefix),
              imageURL.pathExtension.lowercased() == "dmg" else {
            throw UpdateHelperError.invalidImagePath
        }
        let values = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw UpdateHelperError.invalidImagePath
        }
    }
}

private enum ProcessIdentityReader {
    static func identity(pid: Int32) throws -> ParentIdentity {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { throw UpdateHelperError.parentUnavailable }

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, infoSize)
        }
        guard read == infoSize else { throw UpdateHelperError.parentUnavailable }
        let start = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return ParentIdentity(
            pid: pid,
            executableURL: URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self)),
            startTime: Date(timeIntervalSince1970: start)
        )
    }
}

private enum UpdateHelperError: LocalizedError {
    case invalidArguments
    case invalidImagePath
    case parentUnavailable
    case parentDidNotExit

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "The updater received invalid arguments."
        case .invalidImagePath: "The update image is outside Switchboard's protected update folder."
        case .parentUnavailable: "The updater could not verify the parent Switchboard process."
        case .parentDidNotExit: "Switchboard did not exit before the update deadline."
        }
    }
}
