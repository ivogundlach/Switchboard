import ApplicationServices
import Foundation

@main
struct QuitOnCloseMain {
    static func main() {
        if CommandLine.arguments.contains("--accessibility-status") {
            let trusted = AXIsProcessTrusted()
            print("{\"accessibilityTrusted\":\(trusted)}")
            exit(trusted ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--request-accessibility") {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            print("{\"accessibilityTrusted\":\(trusted)}")
            exit(trusted ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        let controller = QuitOnCloseController()
        guard controller.start() else {
            fputs("Quit on Close could not acquire Accessibility event monitoring.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let reporter = QuitOnCloseHealthReporter(controller: controller)
        reporter.start()
        RunLoop.main.run()
    }
}

private final class QuitOnCloseHealthReporter: @unchecked Sendable {
    private let controller: QuitOnCloseController
    private var timer: Timer?

    init(controller: QuitOnCloseController) {
        self.controller = controller
    }

    func start() {
        publish()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    private func publish() {
        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Switchboard/Health", directoryHint: .isDirectory)
        let file = directory.appending(path: "QuitOnClose.json")
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "bundleID": "com.ivogundlach.quit-on-close",
            "pid": getpid(),
            "executablePath": CommandLine.arguments.first ?? "",
            "accessibilityTrusted": AXIsProcessTrusted(),
            "eventTapActive": controller.isRunning,
            "ready": AXIsProcessTrusted() && controller.isRunning,
            "healthNonce": ProcessInfo.processInfo.environment["SWITCHBOARD_HEALTH_NONCE"] ?? "",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            fputs("Quit on Close health report failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
