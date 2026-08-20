import Foundation

struct CopyPathCommandResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

protocol CopyPathCommandRunning {
    func run(executable: String, arguments: [String]) throws -> CopyPathCommandResult
}

final class LocalCopyPathCommandRunner: CopyPathCommandRunning {
    func run(executable: String, arguments: [String]) throws -> CopyPathCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return CopyPathCommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

enum CopyPathActivationError: Error, LocalizedError, Equatable {
    case nonCanonicalBundle(URL)
    case commandFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .nonCanonicalBundle(let url):
            "Copy Path requires the canonical Switchboard installation; received \(url.path)."
        case .commandFailed(let command, let status, let output):
            "Copy Path command \(command) failed (status \(status)): \(output)"
        }
    }
}

struct CopyPathController {
    static let canonicalAppURL = URL(fileURLWithPath: "/Applications/Switchboard.app", isDirectory: true)
    static let canonicalExtensionURL = canonicalAppURL
        .appendingPathComponent("Contents/PlugIns/CopyPathFinderExt.appex", isDirectory: true)
    static let extensionIdentifier = "com.ivo.CopyPath.FinderExt"
    static let pluginkitPath = "/usr/bin/pluginkit"

    let commandRunner: any CopyPathCommandRunning

    init(commandRunner: any CopyPathCommandRunning = LocalCopyPathCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func enable(bundleURL: URL) throws {
        try validateCanonical(bundleURL)
        try run(["-a", Self.canonicalExtensionURL.path])
        try run(["-e", "use", "-i", Self.extensionIdentifier])
    }

    func disable(bundleURL: URL) throws {
        try validateCanonical(bundleURL)
        try run(["-e", "disable", "-i", Self.extensionIdentifier])
    }

    private func validateCanonical(_ bundleURL: URL) throws {
        guard bundleURL.resolvingSymlinksInPath().standardizedFileURL == Self.canonicalAppURL else {
            throw CopyPathActivationError.nonCanonicalBundle(bundleURL)
        }
    }

    private func run(_ arguments: [String]) throws {
        let result = try commandRunner.run(executable: Self.pluginkitPath, arguments: arguments)
        guard result.succeeded else {
            throw CopyPathActivationError.commandFailed(
                ([Self.pluginkitPath] + arguments).joined(separator: " "),
                result.status,
                result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }
}

#if COPY_PATH_FINDER_EXTENSION
import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func copyPath(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        var urls = controller.selectedItemURLs() ?? []
        if urls.isEmpty, let target = controller.targetedURL() {
            urls = [target]
        }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
#endif
