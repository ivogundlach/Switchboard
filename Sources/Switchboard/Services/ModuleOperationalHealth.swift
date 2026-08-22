import Foundation

struct ModuleOperationalHealth: Equatable, Sendable {
    let ready: Bool
    let detail: String
}

struct ModuleHealthProbe: Equatable, Sendable {
    let relativeExecutable: String
    let arguments: [String]
    let timeout: TimeInterval
}

enum ModuleOperationalHealthService {
    static func activationReady(
        moduleID: String,
        commandNames: [String],
        serviceNames: [String],
        ownsScheduledJobs: Bool,
        agentEnabled: Bool,
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ModuleOperationalHealth {
        guard commandsAreOwned(
            commandNames,
            moduleID: moduleID,
            bundleURL: bundleURL,
            homeDirectory: homeDirectory
        ) else {
            return .init(ready: false, detail: "Bundled commands are not the active owner")
        }
        guard servicesAreOwned(
            serviceNames,
            bundleURL: bundleURL,
            homeDirectory: homeDirectory
        ) else {
            return .init(ready: false, detail: "Bundled Services are not the active owner")
        }
        guard !ownsScheduledJobs || agentEnabled else {
            return .init(ready: false, detail: "The Switchboard background agent is not enabled")
        }
        return .init(ready: true, detail: "Bundled ownership is verified")
    }

    static func probes(for moduleID: String) -> [ModuleHealthProbe]? {
        switch moduleID {
        case "desktop.warm-corners", "desktop.kinetics", "desktop.audio-guard",
             "desktop.quit-on-close", "desktop.brightness", "files.copy-path",
             "links.copy-safari-url", "systems.advanced-commands":
            return []
        case "desktop.smart-wake":
            return [.init(
                relativeExecutable: "Modules/desktop.smart-wake/bin/smart-wake-diagnose",
                arguments: ["--check"],
                timeout: 30
            )]
        case "mail.assistant":
            return [.init(
                relativeExecutable: "Helpers/MailAssistant.app/Contents/MacOS/mail-assistant-runner",
                arguments: ["--self-test"],
                timeout: 90
            )]
        case "files.auto-install-dmg":
            return [.init(
                relativeExecutable: "Modules/files.auto-install-dmg/bin/auto-install-dmg-worker",
                arguments: ["--self-test"],
                timeout: 15
            )]
        case "connectors.local-read":
            return [.init(
                relativeExecutable: "Modules/connectors.local-read/bin/codex-read",
                arguments: ["--self-test"],
                timeout: 15
            )]
        case "systems.memory":
            return [
                .init(
                    relativeExecutable: "Modules/systems.memory/bin/memory-transcript-distill",
                    arguments: ["--selftest"],
                    timeout: 60
                ),
                .init(
                    relativeExecutable: "Modules/systems.memory/bin/semantic-index-status",
                    arguments: ["--structural"],
                    timeout: 30
                ),
            ]
        case "systems.codex-improvement":
            return [.init(
                relativeExecutable: "Modules/systems.codex-improvement/bin/weekly-system-improvement",
                arguments: ["--selftest"],
                timeout: 120
            )]
        case "systems.repository-release":
            return [
                .init(
                    relativeExecutable: "Modules/systems.repository-release/bin/app-repo-sync",
                    arguments: ["--status"],
                    timeout: 30
                ),
                .init(
                    relativeExecutable: "Modules/systems.repository-release/bin/personal-repo-sync",
                    arguments: ["--status"],
                    timeout: 30
                ),
            ]
        case "systems.notebooklm":
            return [
                .init(
                    relativeExecutable: "Modules/systems.notebooklm/bin/sync_all.sh",
                    arguments: ["--self-test"],
                    timeout: 30
                ),
                .init(
                    relativeExecutable: "Modules/systems.notebooklm/bin/auth_keepalive.sh",
                    arguments: ["--selftest"],
                    timeout: 30
                ),
            ]
        case "systems.backup-audit":
            return [.init(
                relativeExecutable: "Modules/systems.backup-audit/bin/backup-coverage-audit",
                arguments: ["--ensure-status"],
                timeout: 240
            )]
        default:
            return nil
        }
    }

    static func runProbes(
        for moduleID: String,
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> ModuleOperationalHealth {
        guard let probes = probes(for: moduleID) else {
            return .init(ready: false, detail: "No operational health contract exists")
        }
        for probe in probes {
            let result = await run(
                bundleURL.appending(path: "Contents/Resources").appending(path: probe.relativeExecutable),
                arguments: probe.arguments,
                timeout: probe.timeout,
                bundleURL: bundleURL,
                homeDirectory: homeDirectory
            )
            guard result.ready else { return result }
        }
        return .init(ready: true, detail: probes.isEmpty ? "Operational behavior is verified" : "All operational checks passed")
    }

    private static func commandsAreOwned(
        _ names: [String],
        moduleID: String,
        bundleURL: URL,
        homeDirectory: URL
    ) -> Bool {
        for name in names {
            let destination = homeDirectory.appending(path: ".local/bin").appending(path: name)
            let expected = bundleURL.appending(path: "Contents/Resources/Modules")
                .appending(path: moduleID).appending(path: "bin").appending(path: name)
            guard let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == true,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else {
                return names.isEmpty
            }
            let resolved = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : destination.deletingLastPathComponent().appending(path: target)
            guard resolved.standardizedFileURL == expected.standardizedFileURL else { return false }
        }
        return true
    }

    private static func servicesAreOwned(
        _ names: [String],
        bundleURL: URL,
        homeDirectory: URL
    ) -> Bool {
        for name in names {
            let source = bundleURL.appending(path: "Contents/Resources/Services").appending(path: name)
            let destination = homeDirectory.appending(path: "Library/Services").appending(path: name)
            guard treesMatch(source, destination) else { return false }
        }
        return true
    }

    private static func treesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = treeSnapshot(lhs), let right = treeSnapshot(rhs) else { return false }
        return left == right
    }

    private static func treeSnapshot(_ root: URL) -> [String: Data]? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        ) else { return nil }
        var result: [String: Data] = [:]
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            let relative = String(item.path.dropFirst(root.path.count + 1))
            if values.isDirectory == true {
                result[relative + "/"] = Data()
            } else if values.isRegularFile == true, let data = try? Data(contentsOf: item) {
                result[relative] = data
            } else {
                return nil
            }
        }
        return result
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        bundleURL: URL,
        homeDirectory: URL
    ) async -> ModuleOperationalHealth {
        await Task.detached(priority: .utility) {
            runSynchronously(
                executable,
                arguments: arguments,
                timeout: timeout,
                bundleURL: bundleURL,
                homeDirectory: homeDirectory
            )
        }.value
    }

    private static func runSynchronously(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        bundleURL: URL,
        homeDirectory: URL
    ) -> ModuleOperationalHealth {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .init(ready: false, detail: "Health executable is missing: \(executable.lastPathComponent)")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory.path
        environment["PATH"] = "\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["SWITCHBOARD_RESOURCES_DIR"] = bundleURL.appending(path: "Contents/Resources").path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .init(ready: false, detail: "Health check could not start: \(error.localizedDescription)")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            return .init(ready: false, detail: "Health check timed out: \(executable.lastPathComponent)")
        }
        guard process.terminationStatus == 0 else {
            return .init(
                ready: false,
                detail: "Health check failed (\(process.terminationStatus)): \(executable.lastPathComponent)"
            )
        }
        return .init(ready: true, detail: "\(executable.lastPathComponent) passed")
    }
}
