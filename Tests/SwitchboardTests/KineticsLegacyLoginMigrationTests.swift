import Foundation
import Testing
@testable import Switchboard

struct KineticsLegacyLoginMigrationTests {
    @Test
    func intentIsPersistedBeforeUnregisterAndSelectionStaysAbsent() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        let service = FakeKineticsLegacyLoginService(status: .enabled)
        var selection = Set<String>()
        var order: [String] = []
        var observedState: KineticsLegacyLoginIntentState?
        var agentObservedState: KineticsLegacyLoginIntentState?
        var observedSelection = false
        service.onUnregister = {
            order.append("unregister")
            observedState = try? store.load()?.state
            observedSelection = selection.contains(KineticsLegacyLoginMigration.moduleID)
        }
        let migration = KineticsLegacyLoginMigration(service: service, intentStore: store)

        try migration.enable(
            currentSelection: selection,
            registerSharedAgent: {
                order.append("agent")
                agentObservedState = try store.load()?.state
            },
            validateCompanion: { order.append("companion") },
            persistSelection: { value in
                order.append("selection")
                selection = value
            }
        )

        #expect(order.first == "companion")
        #expect(order.contains("agent"))
        #expect(order.last == "selection")
        #expect(agentObservedState == .planned)
        #expect(observedState == .unregistering)
        #expect(!observedSelection)
        #expect(selection.contains(KineticsLegacyLoginMigration.moduleID))
        #expect(try store.load()?.state == .completed)
    }

    @Test
    func resumeFromUnregisteredCompletesSelectionAfterCrash() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        var intent = KineticsLegacyLoginIntent()
        intent.state = .unregistered
        try store.persist(intent)
        let service = FakeKineticsLegacyLoginService(status: .notRegistered)
        let migration = KineticsLegacyLoginMigration(service: service, intentStore: store)
        var selection = Set<String>()

        #expect(try migration.resume(
            currentSelection: selection,
            registerSharedAgent: {},
            validateCompanion: {},
            persistSelection: { selection = $0 }
        ))
        #expect(selection == [KineticsLegacyLoginMigration.moduleID])
        #expect(try store.load()?.state == .completed)
        #expect(service.unregisterCalls == 0)
    }

    @Test
    func unregisterFailureLeavesSelectionAbsentAndIntentRecoverable() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        let service = FakeKineticsLegacyLoginService(status: .enabled, unregisterError: TestError.failed)
        let migration = KineticsLegacyLoginMigration(service: service, intentStore: store)
        var selection = Set<String>()

        #expect(throws: KineticsLegacyLoginMigrationError.self) {
            try migration.enable(
                currentSelection: selection,
                registerSharedAgent: {},
                validateCompanion: {},
                persistSelection: { selection = $0 }
            )
        }
        #expect(selection.isEmpty)
        #expect(try store.load()?.state == .unregistering)
    }

    @Test
    func requiresApprovalIsUnregisteredAndNoRegistrationAPIIsExposed() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        let service = FakeKineticsLegacyLoginService(status: .requiresApproval)
        let migration = KineticsLegacyLoginMigration(service: service, intentStore: store)
        var agentCalls = 0

        try migration.enable(
            currentSelection: [],
            registerSharedAgent: { agentCalls += 1 },
            validateCompanion: {},
            persistSelection: { _ in }
        )
        #expect(agentCalls == 1)
        #expect(service.unregisterCalls == 1)
        #expect(try store.load()?.state == .completed)
    }

    @Test
    func intentStoreRejectsSymlinkAndWorldReadableState() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        try store.persist(KineticsLegacyLoginIntent())
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: store.fileURL.path)
        #expect(throws: KineticsLegacyLoginMigrationError.worldReadableIntent) { try store.load() }

        let target = root.appending(path: "real-intent.json")
        try FileManager.default.moveItem(at: store.fileURL, to: target)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        #expect(throws: KineticsLegacyLoginMigrationError.unsafeIntentPath) { try store.load() }

        try FileManager.default.removeItem(at: target)
        #expect(throws: KineticsLegacyLoginMigrationError.unsafeIntentPath) { try store.load() }
    }

    @Test
    func healthyReplacementRetiresLegacyLoginOnlyAfterSelectionExists() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        let service = FakeKineticsLegacyLoginService(status: .enabled)
        let migration = KineticsLegacyLoginMigration(service: service, intentStore: store)
        var companionChecks = 0

        try migration.retireLegacyLoginAfterHealthyReplacement(
            currentSelection: [KineticsLegacyLoginMigration.moduleID],
            validateCompanion: { companionChecks += 1 }
        )

        #expect(companionChecks == 2)
        #expect(service.unregisterCalls == 1)
        #expect(try store.load()?.state == .completed)
    }

    @Test
    func legacyLoginIsNotTouchedBeforeHealthyReplacementSelection() throws {
        let root = try makeIntentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsLegacyLoginIntentStore(applicationSupportURL: root)
        let service = FakeKineticsLegacyLoginService(status: .enabled)
        let migration = KineticsLegacyLoginMigration(service: service, intentStore: store)

        #expect(throws: KineticsLegacyLoginMigrationError.invalidIntent) {
            try migration.retireLegacyLoginAfterHealthyReplacement(
                currentSelection: [],
                validateCompanion: {}
            )
        }
        #expect(service.unregisterCalls == 0)
        #expect(try store.load() == nil)
    }

    private func makeIntentRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "switchboard-kinetics-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
        return root
    }
}

private enum TestError: Error { case failed }

private final class FakeKineticsLegacyLoginService: KineticsLegacyLoginService {
    var status: KineticsLegacyLoginStatus
    let unregisterError: Error?
    var unregisterCalls = 0
    var onUnregister: (() throws -> Void)?

    init(status: KineticsLegacyLoginStatus, unregisterError: Error? = nil) {
        self.status = status
        self.unregisterError = unregisterError
    }

    func unregister() throws {
        unregisterCalls += 1
        try onUnregister?()
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
