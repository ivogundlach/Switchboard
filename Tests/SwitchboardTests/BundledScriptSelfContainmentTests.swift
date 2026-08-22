import Foundation
import Testing

struct BundledScriptSelfContainmentTests {
    @Test
    func notebookLMWrappersUseBundledCodeAndFlagsDoNotRunSync() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let code = root.appendingPathComponent("code", isDirectory: true)
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("marker")
        try writeExecutable("#!/bin/bash\nprintf '%s\n' \"$*\" >> \"$NOTEBOOKLM_MARKER\"\n", to: code.appendingPathComponent("sync_all.sh"))
        try writeFile("# bundled Python\n", to: code.appendingPathComponent("notebooklm_sync.py"))

        let environment = [
            "NOTEBOOKLM_CODE_DIR": code.path,
            "NOTEBOOKLM_MARKER": marker.path,
            "NOTEBOOKLM_SYNC_DIR": root.appendingPathComponent("state").path,
        ]
        let ingest = projectURL().appending(path: "Payloads/Modules/systems.notebooklm/bin/ingest_nblm.sh")
        let command = projectURL().appending(path: "Payloads/Modules/systems.notebooklm/bin/Ingest nblm.command")

        for script in [ingest, command] {
            for option in ["--help", "--version", "--self-test"] {
                _ = try run(script, arguments: [option], environment: environment)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        _ = try run(ingest, arguments: ["--probe"], environment: environment)
        #expect(try String(contentsOf: marker, encoding: .utf8).contains("--probe"))
    }

    @Test
    func syncAllUsesBundledPythonAndFlagsDoNotRunNormalWork() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let code = root.appendingPathComponent("code", isDirectory: true)
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("python-marker")
        try writeFile(
            "#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\nPath(os.environ['NOTEBOOKLM_MARKER']).write_text('bundled-python')\n",
            to: code.appendingPathComponent("notebooklm_sync.py")
        )
        try writeExecutable("#!/bin/bash\necho '{\"status\":\"ok\"}'\n", to: root.appendingPathComponent("notebooklm"))

        let state = root.appendingPathComponent("state")
        let environment = [
            "NOTEBOOKLM_CODE_DIR": code.path,
            "NOTEBOOKLM_MARKER": marker.path,
            "NOTEBOOKLM_POWER_SOURCE": "ac",
            "NOTEBOOKLM_BIN": root.appendingPathComponent("notebooklm").path,
            "NOTEBOOKLM_SYNC_DIR": state.path,
            "PATH": "/usr/bin:/bin",
        ]
        let sync = projectURL().appending(path: "Payloads/Modules/systems.notebooklm/bin/sync_all.sh")

        for option in ["--help", "--version", "--self-test"] {
            _ = try run(sync, arguments: [option], environment: environment)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: state.path))

        _ = try run(sync, arguments: [], environment: environment)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "bundled-python")
        #expect(FileManager.default.fileExists(atPath: state.appendingPathComponent("sync_automation.log").path))
    }

    @Test
    func smartWakeDiagnosticUsesItsBundledDirectoryForRuntimeChecks() throws {
        let script = try String(contentsOf: projectURL().appending(path: "Payloads/Modules/desktop.smart-wake/bin/smart-wake-diagnose"), encoding: .utf8)
        #expect(script.contains("CODE_DIR=\"$(CDPATH= cd -- \"$(dirname -- \"${BASH_SOURCE[0]}\")\" && pwd -P)\""))
        #expect(script.contains("CODE_DIR=\"${SMART_WAKE_DIAG_SOURCE_HOME:?SMART_WAKE_DIAG_SOURCE_HOME is required in test mode}\""))
        #expect(!script.contains("SMART_WAKE_HOME/${relative}"))
        let result = try run(
            projectURL().appending(path: "Payloads/Modules/desktop.smart-wake/bin/smart-wake-diagnose"),
            arguments: ["--version"],
            environment: [:]
        )
        #expect(result.output.contains("smart-wake-diagnose 1.0.0"))
    }

    @Test
    func authKeepaliveFlagsAreSideEffectFree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("auth.log")
        let script = projectURL().appending(path: "Payloads/Modules/systems.notebooklm/bin/auth_keepalive.sh")
        let environment = ["HOME": root.path, "NOTEBOOKLM_AUTH_LOG": log.path]
        for option in ["--help", "--version", "--selftest"] {
            _ = try run(script, arguments: [option], environment: environment)
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    private func projectURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try writeFile(contents, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func run(_ script: URL, arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        var merged = ProcessInfo.processInfo.environment
        environment.forEach { merged[$0.key] = $0.value }
        process.environment = merged
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
