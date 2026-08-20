import Foundation
import CryptoKit
import Testing
@testable import Switchboard

struct LegacySchedulerMigrationTests {
    @Test
    func rejectsInvalidAndPrivilegedLabels() {
        #expect(!LegacySchedulerMigration.isValidLabel("../evil"))
        #expect(!LegacySchedulerMigration.isValidLabel("com.example bad"))
        #expect(!LegacySchedulerMigration.isValidLabel("root/com.example.job"))
        #expect(LegacySchedulerMigration.isValidLabel("com.example.job"))
        #expect(LegacySchedulerMigration.isValidLabel(LegacySchedulerMigration.cronLabel))
    }

    @Test
    func refusesPrivilegedEnvironment() {
        let environment = LegacySchedulerMigrationEnvironment(
            homeDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            applicationSupportDirectory: URL(fileURLWithPath: "/Library/Application Support/Switchboard", isDirectory: true),
            userID: 0
        )
        #expect(throws: LegacySchedulerMigrationError.privilegedEnvironment) {
            try LegacySchedulerMigration(
                moduleID: "desktop.test",
                legacyLabels: ["com.example.job"],
                environment: environment,
                fileSystem: FakeFileSystem(),
                commands: FakeCommands(),
                persistence: RecordingPersistence()
            ).migrate()
        }
    }

    @Test
    func freshInstallWithNoLegacySchedulerIsANoOp() throws {
        let record = try LegacySchedulerMigration(
            moduleID: "desktop.test",
            legacyLabels: ["com.example.absent", LegacySchedulerMigration.cronLabel],
            environment: testEnvironment(),
            fileSystem: FakeFileSystem(),
            commands: FakeCommands(),
            persistence: RecordingPersistence()
        ).migrate()
        #expect(record.state == .completed)
        #expect(record.artifacts.count == 1)
        #expect(record.artifacts.first?.wasLoaded == false)
    }

    @Test
    func successfulQuiescenceSnapshotsExactBytesAndHash() throws {
        let fs = FakeFileSystem()
        let commands = FakeCommands()
        let persistence = RecordingPersistence()
        let env = testEnvironment()
        let source = Data("plist bytes\n".utf8)
        let original = env.homeDirectory.appending(path: "Library/LaunchAgents/com.example.job.plist")
        fs.files[original.path] = source
        commands.loaded.insert("com.example.job")

        let migration = LegacySchedulerMigration(
            moduleID: "desktop.test",
            legacyLabels: ["com.example.job"],
            environment: env,
            fileSystem: fs,
            commands: commands,
            persistence: persistence
        )
        let record = try migration.migrate()

        #expect(record.state == .completed)
        #expect(record.artifacts.first?.sha256 == sha256(source))
        #expect(record.artifacts.first?.byteCount == source.count)
        #expect(!fs.files.keys.contains(original.path))
        #expect(persistence.records.contains { $0.events.contains { $0.action.contains("bootout") || $0.action.contains("move intent") } })
        #expect(commands.executions.contains { $0.executable == "/bin/launchctl" && $0.arguments.first == "bootout" })
    }

    @Test
    func persistencePrecedesEachModeledSideEffect() throws {
        let order = SharedOrder()
        let fs = FakeFileSystem(order: order)
        let commands = FakeCommands(order: order)
        let persistence = RecordingPersistence(order: order)
        let env = testEnvironment()
        let original = env.homeDirectory.appending(path: "Library/LaunchAgents/com.example.job.plist")
        fs.files[original.path] = Data("plist".utf8)
        commands.loaded.insert("com.example.job")
        commands.crontab = Data((LegacySchedulerMigration.backupAuditCronLine(homeDirectory: env.homeDirectory) + "\n").utf8)

        _ = try LegacySchedulerMigration(moduleID: "desktop.test", legacyLabels: ["com.example.job", LegacySchedulerMigration.cronLabel], environment: env, fileSystem: fs, commands: commands, persistence: persistence).migrate()
        #expect(persistence.records.count >= 5)
        let bootoutIntent = order.values.firstIndex { $0.contains("bootout intent") }
        let bootout = order.values.firstIndex { $0.contains("cmd:/bin/launchctl:bootout") }
        let moveIntent = order.values.firstIndex { $0.contains("move intent") }
        let move = order.values.firstIndex { $0.hasPrefix("move:") }
        let cronIntent = order.values.firstIndex { $0.contains("cron replacement intent") }
        let cronReplacement = order.values.firstIndex { $0 == "cmd:/usr/bin/crontab:-" }
        #expect(bootoutIntent != nil && bootoutIntent! < bootout!)
        #expect(moveIntent != nil && moveIntent! < move!)
        #expect(cronIntent != nil && cronIntent! < cronReplacement!)
    }

    @Test
    func cronMigrationRemovesOnlyExactLine() throws {
        let fs = FakeFileSystem()
        let commands = FakeCommands()
        let env = testEnvironment()
        let exact = LegacySchedulerMigration.backupAuditCronLine(homeDirectory: env.homeDirectory)
        commands.crontab = Data("one\n\(exact)\none-\(exact)\n".utf8)
        let record = try LegacySchedulerMigration(moduleID: "desktop.test", legacyLabels: [LegacySchedulerMigration.cronLabel], environment: env, fileSystem: fs, commands: commands, persistence: RecordingPersistence()).migrate()
        #expect(record.state == .completed)
        #expect(commands.crontab == Data("one\none-\(exact)\n".utf8))
    }

    @Test
    func rollbackRestoresPlistAndLoadedStateAfterFailure() throws {
        let fs = FakeFileSystem()
        let commands = FakeCommands(failCronReplacement: true)
        let env = testEnvironment()
        let original = env.homeDirectory.appending(path: "Library/LaunchAgents/com.example.job.plist")
        let source = Data("plist".utf8)
        fs.files[original.path] = source
        commands.loaded.insert("com.example.job")
        commands.crontab = Data((LegacySchedulerMigration.backupAuditCronLine(homeDirectory: env.homeDirectory) + "\n").utf8)

        #expect(throws: LegacySchedulerMigrationError.self) {
            try LegacySchedulerMigration(moduleID: "desktop.test", legacyLabels: ["com.example.job", LegacySchedulerMigration.cronLabel], environment: env, fileSystem: fs, commands: commands, persistence: RecordingPersistence()).migrate()
        }
        #expect(fs.files[original.path] == source)
        #expect(commands.loaded.contains("com.example.job"))
    }

    @Test
    func rejectsSymlinkedLegacyPlistBeforeSnapshotMoveOrLaunchctl() {
        let fs = FakeFileSystem()
        let commands = FakeCommands()
        let persistence = RecordingPersistence()
        let env = testEnvironment()
        let original = env.homeDirectory.appending(path: "Library/LaunchAgents/com.example.job.plist")
        fs.files[original.path] = Data("target plist".utf8)
        fs.symbolicLinks.insert(original.path)

        #expect(throws: LegacySchedulerMigrationError.self) {
            try LegacySchedulerMigration(
                moduleID: "desktop.test",
                legacyLabels: ["com.example.job"],
                environment: env,
                fileSystem: fs,
                commands: commands,
                persistence: persistence
            ).migrate()
        }
        #expect(fs.writes.isEmpty)
        #expect(fs.moves.isEmpty)
        #expect(commands.executions.isEmpty)
        #expect(persistence.records.isEmpty)
    }

    private func testEnvironment() -> LegacySchedulerMigrationEnvironment {
        LegacySchedulerMigrationEnvironment(
            homeDirectory: URL(fileURLWithPath: "/test-home", isDirectory: true),
            applicationSupportDirectory: URL(fileURLWithPath: "/test-support", isDirectory: true),
            userID: 501
        )
    }

    private func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeFileSystem: LegacySchedulerFileSystem {
    var files: [String: Data] = [:]
    var symbolicLinks: Set<String> = []
    var writes: [String] = []
    var moves: [String] = []
    let order: SharedOrder

    init(order: SharedOrder = SharedOrder()) { self.order = order }

    func metadata(at url: URL) throws -> LegacySchedulerFileMetadata {
        if symbolicLinks.contains(url.path) {
            return LegacySchedulerFileMetadata(exists: true, isSymbolicLink: true, isRegularFile: false)
        }
        return LegacySchedulerFileMetadata(
            exists: files[url.path] != nil,
            isSymbolicLink: false,
            isRegularFile: files[url.path] != nil
        )
    }
    func read(_ url: URL) throws -> Data { files[url.path] ?? Data() }
    func write(_ data: Data, to url: URL, permissions: UInt16) throws {
        order.values.append("write:\(url.path)")
        writes.append(url.path)
        files[url.path] = data
    }
    func createDirectory(_ url: URL, permissions: UInt16) throws { order.values.append("mkdir:\(url.path)") }
    func move(_ source: URL, to destination: URL) throws {
        order.values.append("move:\(source.path)->\(destination.path)")
        moves.append("\(source.path)->\(destination.path)")
        guard let data = files.removeValue(forKey: source.path) else { throw CocoaError(.fileNoSuchFile) }
        files[destination.path] = data
    }
}

private final class FakeCommands: LegacySchedulerCommandRunning {
    struct Execution { let executable: String; let arguments: [String]; let input: Data? }
    var executions: [Execution] = []
    let order: SharedOrder
    var loaded = Set<String>()
    var crontab = Data()
    let failCronReplacement: Bool

    init(failCronReplacement: Bool = false, order: SharedOrder = SharedOrder()) {
        self.failCronReplacement = failCronReplacement
        self.order = order
    }

    func run(executable: String, arguments: [String], input: Data?) throws -> LegacySchedulerCommandResult {
        executions.append(.init(executable: executable, arguments: arguments, input: input))
        order.values.append("cmd:\(executable):\(arguments.joined(separator: ","))")
        if executable == "/bin/launchctl" {
            let label = arguments.last?.split(separator: "/").last.map(String.init) ?? ""
            if arguments.first == "print" { return .init(status: loaded.contains(label) ? 0 : 1, stdout: Data(), stderr: Data()) }
            if arguments.first == "bootout" { loaded.remove(label); return .init(status: 0, stdout: Data(), stderr: Data()) }
            if arguments.first == "bootstrap" { loaded.insert(label.replacingOccurrences(of: ".plist", with: "")); return .init(status: 0, stdout: Data(), stderr: Data()) }
        }
        if executable == "/usr/bin/crontab" {
            if arguments == ["-l"] { return .init(status: 0, stdout: crontab, stderr: Data()) }
            if arguments == ["-"] {
                if failCronReplacement { return .init(status: 1, stdout: Data(), stderr: Data()) }
                crontab = input ?? Data()
                return .init(status: 0, stdout: Data(), stderr: Data())
            }
        }
        return .init(status: 1, stdout: Data(), stderr: Data())
    }
}

private final class SharedOrder {
    var values: [String] = []
}

private final class RecordingPersistence: LegacySchedulerStatePersisting {
    var records: [LegacySchedulerMigrationRecord] = []
    let order: SharedOrder?
    let commandOrder: SharedOrder?

    init(order: SharedOrder? = nil, commandOrder: SharedOrder? = nil) {
        self.order = order
        self.commandOrder = commandOrder
    }

    func persist(_ record: LegacySchedulerMigrationRecord) throws {
        records.append(record)
        if let action = record.events.last?.action {
            order?.values.append("persist:\(action)")
            commandOrder?.values.append("persist:\(action)")
        }
    }
}
