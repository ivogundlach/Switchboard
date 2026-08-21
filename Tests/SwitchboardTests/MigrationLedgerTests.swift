import Foundation
import Testing
@testable import Switchboard

struct MigrationLedgerTests {
    @Test
    func forwardTransactionRequiresEveryGate() throws {
        var record = MigrationRecord(componentID: "desktop.warm-corners", now: .distantPast)
        try record.transition(to: .preflighted, note: "preflight")
        try record.transition(to: .snapshotting, note: "snapshot intent")
        try record.transition(to: .snapshotted, note: "snapshot verified")
        try record.transition(to: .quiescing, note: "quiescence intent")
        try record.transition(to: .quiesced, note: "old watcher stopped")
        try record.transition(to: .installingReplacement, note: "install intent")
        try record.transition(to: .replacementInstalled, note: "replacement installed")
        try record.transition(to: .replacementRegistered, note: "replacement registered")
        try record.transition(to: .healthVerified, note: "health passed")
        try record.transition(to: .stabilizing, note: "stabilization started")
        try record.transition(to: .retired, note: "legacy retired")

        #expect(record.state == .retired)
        #expect(record.events.map(\.state) == [
            .planned, .preflighted, .snapshotting, .snapshotted,
            .quiescing, .quiesced,
            .installingReplacement, .replacementInstalled,
            .replacementRegistered, .healthVerified, .stabilizing, .retired,
        ])
    }

    @Test
    func retirementCannotSkipStabilization() throws {
        var record = MigrationRecord(componentID: "desktop.warm-corners")
        try record.transition(to: .preflighted, note: "preflight")
        #expect(throws: MigrationLedgerError.self) {
            try record.transition(to: .retired, note: "unsafe skip")
        }
    }

    @Test
    func interruptedStatesAreRecoverable() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let ledger = MigrationLedger(fileURL: temporary.appending(path: "ledger.json"))

        var stable = MigrationRecord(componentID: "stable")
        try stable.transition(to: .preflighted, note: "preflight")

        var interrupted = MigrationRecord(componentID: "interrupted")
        try interrupted.transition(to: .preflighted, note: "preflight")
        try interrupted.transition(to: .snapshotting, note: "snapshot intent")
        try interrupted.transition(to: .snapshotted, note: "snapshot verified")
        try interrupted.transition(to: .quiescing, note: "stopping")
        try interrupted.transition(to: .quiesced, note: "stopped")

        try ledger.save([stable, interrupted])
        let recovered = try ledger.interruptedRecords()

        #expect(recovered.map(\.componentID) == ["interrupted"])
        #expect(recovered.first?.state == .quiesced)
    }

    @Test
    func rollbackIsAvailableAfterReplacementStarts() throws {
        var record = MigrationRecord(componentID: "desktop.warm-corners")
        try record.transition(to: .preflighted, note: "preflight")
        try record.transition(to: .snapshotting, note: "snapshot intent")
        try record.transition(to: .snapshotted, note: "snapshot verified")
        try record.transition(to: .quiescing, note: "stopping")
        try record.transition(to: .quiesced, note: "stopped")
        try record.transition(to: .installingReplacement, note: "installing")
        try record.transition(to: .replacementInstalled, note: "installed")
        try record.transition(to: .rollingBack, note: "health failure")
        try record.transition(to: .rolledBack, note: "legacy restored")
        #expect(record.state == .rolledBack)
    }

    @Test
    func everyTransitionEdgeMatchesThePublishedStateMachine() {
        let allowed: Set<String> = [
            "planned>preflighted",
            "preflighted>snapshotting",
            "snapshotting>snapshotted",
            "snapshotted>quiescing",
            "quiescing>quiesced",
            "quiesced>installingReplacement",
            "installingReplacement>replacementInstalled",
            "replacementInstalled>replacementRegistered",
            "replacementRegistered>healthVerified",
            "healthVerified>stabilizing",
            "stabilizing>retired",
            "snapshotting>rollingBack",
            "snapshotted>rollingBack",
            "quiescing>rollingBack",
            "quiesced>rollingBack",
            "installingReplacement>rollingBack",
            "replacementInstalled>rollingBack",
            "replacementRegistered>rollingBack",
            "healthVerified>rollingBack",
            "stabilizing>rollingBack",
            "rollingBack>rolledBack",
        ]

        for from in MigrationState.allCases {
            for to in MigrationState.allCases where to != .failed {
                let key = "\(from.rawValue)>\(to.rawValue)"
                #expect(from.canTransition(to: to) == allowed.contains(key))
            }
            #expect(from.canTransition(to: .failed))
        }
    }

    @Test
    func everyPersistedInterruptionBoundaryIsDetected() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let ledger = MigrationLedger(fileURL: temporary.appending(path: "ledger.json"))

        var record = MigrationRecord(componentID: "pilot")
        let path: [MigrationState] = [
            .preflighted, .snapshotting, .snapshotted,
            .quiescing, .quiesced, .installingReplacement,
            .replacementInstalled, .replacementRegistered,
            .healthVerified, .stabilizing,
        ]
        for state in path {
            try record.transition(to: state, note: state.rawValue)
            try ledger.save([record])
            let interrupted = try ledger.interruptedRecords()
            #expect(interrupted.count == (state.needsRecoveryAfterInterruption ? 1 : 0))
            #expect(interrupted.first?.state == (state.needsRecoveryAfterInterruption ? state : nil))
        }

        try record.transition(to: .rollingBack, note: "rollback")
        try ledger.save([record])
        #expect(try ledger.interruptedRecords().first?.state == .rollingBack)
        try record.transition(to: .rolledBack, note: "restored")
        try ledger.save([record])
        #expect(try ledger.interruptedRecords().isEmpty)
    }

    @Test
    func ledgerReadsLegacyNumericDatesAndCurrentISO8601Dates() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appending(path: "ledger.json")
        let ledger = MigrationLedger(fileURL: url)
        let record = MigrationRecord(componentID: "pilot", now: Date(timeIntervalSinceReferenceDate: 1234))

        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try JSONEncoder().encode([record]).write(to: url)
        #expect(try ledger.load().first?.createdAt == record.createdAt)

        try ledger.save([record])
        #expect(try ledger.load() == [record])
    }

    @Test
    func malformedLedgerDateFailsClosed() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appending(path: "ledger.json")
        let ledger = MigrationLedger(fileURL: url)
        let record = MigrationRecord(componentID: "pilot", now: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var text = String(decoding: try encoder.encode([record]), as: UTF8.self)
        text = text.replacingOccurrences(of: "1970-01-01T00:00:00Z", with: "not-a-date")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        #expect(throws: DecodingError.self) { try ledger.load() }
    }

    @Test
    func recoveryStoreSnapshotsExactBytesAndDetectsTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let source = Data("sanitized legacy settings".utf8)
        let original = source
        let transactionID = UUID()

        let artifact = try store.snapshot(data: source, name: "warm-corners-settings.json", transactionID: transactionID)
        #expect(try store.restore(artifact) == source)
        #expect(source == original)

        let artifactURL = root.appending(path: artifact.relativePath)
        try Data("tampered".utf8).write(to: artifactURL)
        #expect(throws: MigrationLedgerError.self) { try store.restore(artifact) }
    }

    @Test
    func recoveryStoreRejectsTraversalNames() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = RecoveryStore(rootURL: root)
        #expect(throws: MigrationLedgerError.self) {
            try store.snapshot(data: Data(), name: "../settings", transactionID: UUID())
        }
    }
}

struct ModuleSelectionPolicyTests {
    @Test
    func onlyVerifiedModulesCanBeEnabled() {
        let modules = [
            Self.module(id: "pilot", availability: .pilot),
            Self.module(id: "ready", availability: .ready),
            Self.module(id: "planned", availability: .planned),
            Self.module(id: "repair", availability: .repairRequired),
            Self.module(id: "inventory", availability: .classificationRequired),
        ]
        #expect(ModuleSelectionPolicy.sanitizedEnabledIDs(Set(modules.map(\.id)), modules: modules) == Set(["pilot", "ready"]))
        #expect(ModuleSelectionPolicy.canEnable(modules[0]))
        #expect(ModuleSelectionPolicy.canEnable(modules[1]))
        #expect(!ModuleSelectionPolicy.canEnable(modules[2]))
        #expect(!ModuleSelectionPolicy.canEnable(modules[3]))
        #expect(!ModuleSelectionPolicy.canEnable(modules[4]))
    }

    private static func module(id: String, availability: ModuleDefinition.Availability) -> ModuleDefinition {
        ModuleDefinition(
            id: id,
            name: id,
            group: "test",
            purpose: "test",
            owner: .switchboard,
            availability: availability,
            components: [],
            permissionCategories: [],
            legacyLabels: [],
            legacyBundleIDs: [],
            configKeys: []
        )
    }
}

struct WarmCornerSettingsCodecTests {
    @Test
    func legacyPayloadImportsWithFullFidelityAndLeavesInputUnchanged() throws {
        let legacyData = Data(#"{"actions":{"topLeft":{"appPath":"/Applications/TextEdit.app","delay":1.25},"bottomRight":{"appPath":null,"delay":0.1}},"showIndicator":false,"isPaused":true}"#.utf8)
        let expected = WarmCornerSettingsPayload(
            actions: [
                WarmCorner.topLeft.rawValue: WarmCornerAction(appPath: "/Applications/TextEdit.app", delay: 1.25),
                WarmCorner.bottomRight.rawValue: WarmCornerAction(appPath: nil, delay: 0.1),
            ],
            showIndicator: false,
            isPaused: true
        )
        let original = legacyData

        let (first, firstSource) = WarmCornerSettingsCodec.select(currentData: nil, legacyData: legacyData)
        let currentData = try JSONEncoder().encode(first)
        let (second, secondSource) = WarmCornerSettingsCodec.select(currentData: currentData, legacyData: legacyData)

        #expect(first == expected)
        #expect(second == expected)
        #expect(firstSource == .legacy)
        #expect(secondSource == .current)
        #expect(legacyData == original)
    }

    @Test
    func malformedCurrentFallsBackToValidLegacyAndMalformedEverythingUsesDefaults() throws {
        let legacy = WarmCornerSettingsPayload(showIndicator: false, isPaused: true)
        let legacyData = try JSONEncoder().encode(legacy)
        let malformed = Data("not-json".utf8)

        let (recovered, source) = WarmCornerSettingsCodec.select(currentData: malformed, legacyData: legacyData)
        #expect(recovered == legacy)
        #expect(source == .legacy)

        let (defaults, defaultSource) = WarmCornerSettingsCodec.select(currentData: malformed, legacyData: malformed)
        #expect(defaults == WarmCornerSettingsPayload())
        #expect(defaultSource == .defaults)
    }

    @Test
    func olderPayloadsWithMissingFieldsReceiveLegacyDefaults() throws {
        let oldPayload = Data(#"{"actions":{"topLeft":{"appPath":"/Applications/TextEdit.app"}}}"#.utf8)
        let decoded = try #require(WarmCornerSettingsCodec.decode(oldPayload))
        #expect(decoded.showIndicator)
        #expect(!decoded.isPaused)
        #expect(decoded.actions[WarmCorner.topLeft.rawValue]?.delay == 0.5)
    }

    @Test @MainActor
    func pauseCallbackCanCancelPendingRuntimeWork() {
        let suite = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WarmCornerSettings(defaults: defaults)
        var observed: Bool?
        settings.onPauseChanged = { observed = $0 }
        settings.isPaused = true
        #expect(observed == true)
    }
}

struct WarmCornerDwellEngineTests {
    private let topLeft = WarmCornerHit(corner: .topLeft, screenID: "1")

    @Test
    func dwellFiresOnceAndRequiresLeavingReleaseZone() {
        var engine = WarmCornerDwellEngine()
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: 0.5) == .start(delay: 0.5))
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: 0.5) == .none)
        let didFire = engine.timerFired(expected: topLeft, current: topLeft)
        #expect(didFire)
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: 0.5) == .none)
        #expect(engine.pointerMoved(candidate: nil, isActive: false, delay: 0) == .none)
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: 0.5) == .start(delay: 0.5))
    }

    @Test
    func leavingEarlyCancelsAndWrongCornerCannotFire() {
        var engine = WarmCornerDwellEngine()
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: 1) == .start(delay: 1))
        #expect(engine.pointerMoved(candidate: nil, isActive: false, delay: 0) == .cancel)
        let didFireAfterExit = engine.timerFired(expected: topLeft, current: nil)
        #expect(!didFireAfterExit)

        let other = WarmCornerHit(corner: .topRight, screenID: "1")
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: 0) == .start(delay: 0))
        let didFireWrongCorner = engine.timerFired(expected: topLeft, current: other)
        #expect(!didFireWrongCorner)
    }

    @Test
    func inactiveAndNegativeDelayAreSafe() {
        var engine = WarmCornerDwellEngine()
        #expect(engine.pointerMoved(candidate: topLeft, isActive: false, delay: -2) == .none)
        #expect(engine.pointerMoved(candidate: topLeft, isActive: true, delay: -2) == .start(delay: 0))
    }


    @Test
    func identicalCornersOnDifferentDisplaysAreDifferentHits() {
        var engine = WarmCornerDwellEngine()
        let first = WarmCornerHit(corner: .topLeft, screenID: "display-1")
        let second = WarmCornerHit(corner: .topLeft, screenID: "display-2")
        #expect(engine.pointerMoved(candidate: first, isActive: true, delay: 1) == .start(delay: 1))
        #expect(engine.pointerMoved(candidate: second, isActive: true, delay: 1) == .start(delay: 1))
        let wrongDisplayDidFire = engine.timerFired(expected: first, current: second)
        #expect(!wrongDisplayDidFire)
    }
}

struct WarmCornerTargetPolicyTests {
    @Test
    func missingAndUnassignedTargetsFailClosed() {
        let missing = WarmCornerAction(appPath: "/Applications/Missing.app", delay: 0.5)
        let none = WarmCornerAction(appPath: nil, delay: 0.5)
        #expect(WarmCornerTargetPolicy.urlToOpen(action: missing, fileExists: { _ in false }) == nil)
        #expect(WarmCornerTargetPolicy.urlToOpen(action: none, fileExists: { _ in true }) == nil)
    }

    @Test
    func existingApplicationReturnsItsExactURL() {
        let action = WarmCornerAction(appPath: "/Applications/TextEdit.app", delay: 0.5)
        let result = WarmCornerTargetPolicy.urlToOpen(
            action: action,
            fileExists: { $0 == "/Applications/TextEdit.app" },
            applicationValidator: { _ in true }
        )
        #expect(result?.path == "/Applications/TextEdit.app")
    }

    @Test
    func openerRunsExactlyOnceForAnExistingTarget() {
        let action = WarmCornerAction(appPath: "/Applications/TextEdit.app", delay: 0)
        var calls = 0
        let opened = WarmCornerOpenAction.perform(
            action: action,
            fileExists: { _ in true },
            applicationValidator: { _ in true },
            opener: { _ in calls += 1; return true }
        )
        #expect(opened)
        #expect(calls == 1)
    }

    @Test
    func openerDoesNotRunForAMissingTarget() {
        let action = WarmCornerAction(appPath: "/Applications/Missing.app", delay: 0)
        var calls = 0
        let opened = WarmCornerOpenAction.perform(
            action: action,
            fileExists: { _ in false },
            applicationValidator: { _ in true },
            opener: { _ in calls += 1; return true }
        )
        #expect(!opened)
        #expect(calls == 0)
    }

    @Test
    func defaultValidatorRejectsNonApplicationsAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let plain = root.appending(path: "Plain.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!WarmCornerTargetPolicy.isValidApplicationBundle(plain))

        let valid = root.appending(path: "Valid.app", directoryHint: .isDirectory)
        let contents = valid.appending(path: "Contents", directoryHint: .isDirectory)
        let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appending(path: "Valid")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.valid",
            "CFBundleExecutable": "Valid",
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appending(path: "Info.plist"))
        #expect(WarmCornerTargetPolicy.isValidApplicationBundle(valid))

        let link = root.appending(path: "Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        #expect(!WarmCornerTargetPolicy.isValidApplicationBundle(link))
    }
}

struct WarmCornerIndicatorTests {
    @Test @MainActor
    func indicatorOriginsStayInsideEveryScreenCorner() {
        let frame = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 64, height: 64)
        for corner in WarmCorner.allCases {
            let origin = WarmCornerIndicator.origin(corner: corner, screenFrame: frame, size: size)
            #expect(frame.contains(CGPoint(x: origin.x, y: origin.y)))
            #expect(frame.contains(CGPoint(x: origin.x + size.width, y: origin.y + size.height)))
        }
    }
}

@MainActor
private final class FakeWarmCornerEventMonitor: WarmCornerEventMonitoring {
    var handles: WarmCornerMonitorHandles
    private(set) var removedCount = 0
    private(set) var installCount = 0

    init(global: Bool, local: Bool) {
        handles = WarmCornerMonitorHandles(
            global: global ? NSObject() : nil,
            local: local ? NSObject() : nil
        )
    }

    func install(handler: @escaping () -> Void) -> WarmCornerMonitorHandles {
        installCount += 1
        return handles
    }
    func remove(_ monitorHandle: Any) { removedCount += 1 }
}

struct WarmCornerRuntimeLifecycleTests {
    @Test @MainActor
    func monitorRegistrationFailureLeavesRuntimeStopped() {
        let defaults = isolatedDefaults()
        let monitor = FakeWarmCornerEventMonitor(global: false, local: false)
        let runtime = WarmCornerRuntime(
            settings: WarmCornerSettings(defaults: defaults.store),
            eventMonitor: monitor
        )
        runtime.start()
        #expect(!runtime.isRunning)
        defaults.cleanup()
    }

    @Test @MainActor
    func stopRemovesEveryInstalledMonitor() {
        let defaults = isolatedDefaults()
        let monitor = FakeWarmCornerEventMonitor(global: true, local: true)
        let runtime = WarmCornerRuntime(
            settings: WarmCornerSettings(defaults: defaults.store),
            eventMonitor: monitor
        )
        runtime.start()
        #expect(runtime.isRunning)
        runtime.stop()
        #expect(!runtime.isRunning)
        #expect(monitor.removedCount == 2)
        defaults.cleanup()
    }

    @Test @MainActor
    func eitherPartialMonitorInstallationFailsClosedAndRemovesThePartialHandle() {
        for pair in [(global: true, local: false), (global: false, local: true)] {
            let defaults = isolatedDefaults()
            let monitor = FakeWarmCornerEventMonitor(global: pair.global, local: pair.local)
            let runtime = WarmCornerRuntime(
                settings: WarmCornerSettings(defaults: defaults.store),
                eventMonitor: monitor
            )
            runtime.start()
            #expect(!runtime.isRunning)
            #expect(monitor.removedCount == 1)
            defaults.cleanup()
        }
    }

    @Test @MainActor
    func restartReplacesTheCompleteMonitorPair() {
        let defaults = isolatedDefaults()
        let monitor = FakeWarmCornerEventMonitor(global: true, local: true)
        let runtime = WarmCornerRuntime(
            settings: WarmCornerSettings(defaults: defaults.store),
            eventMonitor: monitor
        )
        runtime.start()
        #expect(runtime.restart())
        #expect(runtime.isRunning)
        #expect(monitor.installCount == 2)
        #expect(monitor.removedCount == 2)
        defaults.cleanup()
    }

    @MainActor
    private func isolatedDefaults() -> (store: UserDefaults, cleanup: () -> Void) {
        let name = "SwitchboardTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (store, { store.removePersistentDomain(forName: name) })
    }
}

struct WarmCornersMigrationServiceTests {
    @Test @MainActor
    func existingLegacyDataFailsClosedWithoutAQuiescenceContract() async throws {
        let fixture = legacyFixture()
        let environment = try makeEnvironment(legacyData: fixture)
        defer { environment.cleanup() }

        await #expect(throws: WarmCornersMigrationError.self) {
            try await environment.service.importLegacyIfNeeded()
        }
        #expect(!environment.settings.hasStoredConfiguration)
        #expect(!FileManager.default.fileExists(atPath: environment.ledger.fileURL.path))
    }

    @Test @MainActor
    func transactionalImportSnapshotsExactLegacyBytesAndReachesStabilization() async throws {
        let fixture = legacyFixture()
        let environment = try makeEnvironment(
            legacyData: fixture,
            quiesceLegacy: { .verified }
        )
        defer { environment.cleanup() }

        #expect(try await environment.service.importLegacyIfNeeded())
        let records = try environment.ledger.load()
        let record = try #require(records.first)
        let artifact = try #require(record.recoveryArtifact)
        #expect(record.state == .stabilizing)
        #expect(try environment.recovery.restore(artifact) == fixture)
        #expect(WarmCornerSettingsCodec.decode(environment.settings.encodedData()!) == WarmCornerSettingsCodec.decode(fixture))
    }

    @Test @MainActor
    func quiescenceFailureLeavesReplacementSettingsAbsentAndRecordsFailure() async throws {
        let fixture = legacyFixture()
        let environment = try makeEnvironment(
            legacyData: fixture,
            quiesceLegacy: { throw TestMigrationError.quiescenceFailed }
        )
        defer { environment.cleanup() }

        await #expect(throws: TestMigrationError.self) {
            try await environment.service.importLegacyIfNeeded()
        }
        #expect(!environment.settings.hasStoredConfiguration)
        let record = try #require(environment.ledger.load().first)
        #expect(record.state == .rolledBack)
        #expect(record.recoveryArtifact != nil)
    }

    @Test @MainActor
    func unverifiedQuiescenceEvidenceRollsBackWithoutImportingSettings() async throws {
        let fixture = legacyFixture()
        let environment = try makeEnvironment(
            legacyData: fixture,
            quiesceLegacy: {
                LegacyQuiescenceEvidence(
                    watcherProcessAbsent: false,
                    loginRegistrationDisabled: true
                )
            }
        )
        defer { environment.cleanup() }

        await #expect(throws: WarmCornersMigrationError.self) {
            try await environment.service.importLegacyIfNeeded()
        }
        #expect(!environment.settings.hasStoredConfiguration)
        #expect(try environment.ledger.load().first?.state == .rolledBack)
    }

    @Test @MainActor
    func persistedReplacementSettingsStillRequireVerifiedLegacyStatus() async throws {
        let fixture = legacyFixture()
        let environment = try makeEnvironment(
            legacyData: fixture,
            legacyStatusProvider: {
                LegacyQuiescenceEvidence(
                    watcherProcessAbsent: false,
                    loginRegistrationDisabled: true
                )
            }
        )
        defer { environment.cleanup() }
        let payload = try #require(WarmCornerSettingsCodec.decode(fixture))
        environment.settings.applyImportedPayload(payload)

        await #expect(throws: WarmCornersMigrationError.self) {
            try await environment.service.importLegacyIfNeeded()
        }
        #expect(environment.settings.hasStoredConfiguration)
        #expect(!FileManager.default.fileExists(atPath: environment.ledger.fileURL.path))
    }

    @MainActor
    private func makeEnvironment(
        legacyData: Data,
        quiesceLegacy: WarmCornersMigrationService.LegacyQuiescence? = nil,
        legacyStatusProvider: WarmCornersMigrationService.LegacyStatusProvider? = nil
    ) throws -> (
        service: WarmCornersMigrationService,
        settings: WarmCornerSettings,
        ledger: MigrationLedger,
        recovery: RecoveryStore,
        cleanup: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let defaultsName = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let settings = WarmCornerSettings(defaults: defaults)
        let ledger = MigrationLedger(fileURL: root.appending(path: "ledger.json"))
        let recovery = RecoveryStore(rootURL: root.appending(path: "Recovery", directoryHint: .isDirectory))
        let service = WarmCornersMigrationService(
            settings: settings,
            coordinator: OperationCoordinator(),
            ledger: ledger,
            recoveryStore: recovery,
            legacyDataProvider: { legacyData },
            quiesceLegacy: quiesceLegacy,
            legacyStatusProvider: legacyStatusProvider
        )
        return (
            service,
            settings,
            ledger,
            recovery,
            {
                defaults.removePersistentDomain(forName: defaultsName)
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    private func legacyFixture() -> Data {
        Data(#"{"actions":{"topLeft":{"appPath":"/Applications/TextEdit.app","delay":0.75}},"showIndicator":true,"isPaused":false}"#.utf8)
    }
}

private enum TestMigrationError: Error {
    case quiescenceFailed
}

struct ManifestValidatorTests {
    @Test
    func currentManifestPassesAllOwnershipBoundaries() throws {
        let manifest = try loadManifest()
        try ManifestValidator.validate(manifest)
        try loadBaseline().validate(manifest)
    }

    @Test
    func duplicateCommandAndUnknownOwnerFailClosed() throws {
        let manifest = try loadManifest()
        var duplicateFamilies = manifest.ownedCommandFamilies
        duplicateFamilies.append(OwnedCommandFamily(owner: "switchboard:desktop.warm-corners", items: ["copy-safari-url"]))
        let duplicate = replacing(manifest, commandFamilies: duplicateFamilies)
        #expect(throws: SelfTestError.self) { try ManifestValidator.validate(duplicate) }

        var unknownFamilies = manifest.ownedCommandFamilies
        unknownFamilies.append(OwnedCommandFamily(owner: "switchboard:not-a-module", items: ["unique-test-command"]))
        let unknown = replacing(manifest, commandFamilies: unknownFamilies)
        #expect(throws: SelfTestError.self) { try ManifestValidator.validate(unknown) }
    }

    private func loadManifest() throws -> ModuleManifest {
        let project = projectURL()
        let url = project.appending(path: "Sources/Switchboard/Resources/ModuleManifest.json")
        return try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: url))
    }

    private func loadBaseline() throws -> InventoryBaseline {
        let url = projectURL().appending(path: "Sources/Switchboard/Resources/InventoryBaseline.json")
        return try JSONDecoder().decode(InventoryBaseline.self, from: Data(contentsOf: url))
    }

    private func projectURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func replacing(
        _ manifest: ModuleManifest,
        commandFamilies: [OwnedCommandFamily]
    ) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: manifest.schemaVersion,
            supportedPlatform: manifest.supportedPlatform,
            modules: manifest.modules,
            scheduledComponents: manifest.scheduledComponents,
            ownedCommandFamilies: commandFamilies,
            memoryToolCandidates: manifest.memoryToolCandidates,
            macOSServices: manifest.macOSServices,
            standaloneProducts: manifest.standaloneProducts,
            separateSafariApps: manifest.separateSafariApps,
            excludedShortcuts: manifest.excludedShortcuts,
            replacedShortcuts: manifest.replacedShortcuts,
            excludedThirdPartyUtilities: manifest.excludedThirdPartyUtilities,
            excludedSupersededOrDeleted: manifest.excludedSupersededOrDeleted
        )
    }
}
