import Darwin
import Foundation
import Testing
@testable import Switchboard

struct UpgradeRecoveryTests {
    @Test(arguments: [
        KineticsUpgradeHandoffPhase.planned,
        .stopIntent,
        .legacyStopped,
        .replacementSelected,
        .replacementHealthy,
    ])
    func kineticsRecoveryRollsBackBeforeLegacyLoginRetirement(
        phase: KineticsUpgradeHandoffPhase
    ) {
        #expect(KineticsUpgradeRecoveryAction.decide(
            phase: phase,
            legacyLoginStatus: .enabled
        ) == .rollbackToLegacy)
    }

    @Test
    func kineticsRecoveryKeepsReplacementWhenLoginRetirementIsUncertainOrComplete() {
        #expect(KineticsUpgradeRecoveryAction.decide(
            phase: .legacyLoginRetirementIntent,
            legacyLoginStatus: .notRegistered
        ) == .keepReplacementPending)
        #expect(KineticsUpgradeRecoveryAction.decide(
            phase: .legacyLoginRetirementIntent,
            legacyLoginStatus: .unknown
        ) == .keepReplacementPending)
        #expect(KineticsUpgradeRecoveryAction.decide(
            phase: .legacyLoginRetired,
            legacyLoginStatus: .enabled
        ) == .keepReplacementPending)
    }

    @Test
    func kineticsRecoveryCanRollBackWhenLoginRetirementNeverTookEffect() {
        #expect(KineticsUpgradeRecoveryAction.decide(
            phase: .legacyLoginRetirementIntent,
            legacyLoginStatus: .enabled
        ) == .rollbackToLegacy)
    }

    @Test
    func kineticsHandoffJournalIsOwnerOnlyAndRoundTripsEveryIntent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KineticsUpgradeHandoffStore(supportURL: root)
        var record = try store.begin(
            healthNonce: UUID().uuidString,
            legacyAppPath: "/Applications/Kinetics.app",
            legacyExecutableName: "Kinetics",
            legacyWasRunning: true,
            priorSelection: ["desktop.warm-corners"]
        )
        for phase in [
            KineticsUpgradeHandoffPhase.stopIntent, .legacyStopped, .replacementSelected,
            .replacementHealthy, .legacyLoginRetirementIntent, .legacyLoginRetired, .committed,
        ] {
            record = try store.transition(record, to: phase)
            #expect(try store.load()?.phase == phase)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func helperHealthRequiresCurrentProcessExactPathAndAttemptNonce() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = try currentExecutableURL()
        let healthDirectory = home.appending(path: "Library/Application Support/Switchboard/Health")
        try FileManager.default.createDirectory(at: healthDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: healthDirectory.path)
        let nonce = UUID().uuidString
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "bundleID": "test.helper",
            "pid": getpid(),
            "executablePath": executable.path,
            "accessibilityTrusted": true,
            "eventTapActive": true,
            "ready": true,
            "healthNonce": nonce,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let url = healthDirectory.appending(path: "Test.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        #expect(ReplacementHealthService.helperCapability(
            named: "Test",
            expectedBundleID: "test.helper",
            expectedExecutableURL: executable,
            expectedNonce: nonce,
            homeDirectory: home
        ).ready)
        #expect(!ReplacementHealthService.helperCapability(
            named: "Test",
            expectedBundleID: "test.helper",
            expectedExecutableURL: executable,
            expectedNonce: UUID().uuidString,
            homeDirectory: home
        ).ready)
    }

    @Test
    func agentHeartbeatRequiresExactNonceAndPrivateState() throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let executable = try currentExecutableURL()
        let nonce = UUID().uuidString
        let state = AgentStateFile(jobs: [
            "test.job": AgentJobState(
                lastAttempt: Date(),
                lastSuccess: nil,
                lastFailure: nil,
                runningPID: getpid(),
                runningExecutablePath: executable.path,
                heartbeat: Date(),
                healthNonce: nonce,
                processStartedAt: Date()
            ),
        ])
        let url = support.appending(path: "agent-state.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(ReplacementHealthService.continuousAgentJob(
            label: "test.job",
            expectedExecutableURL: executable,
            expectedNonce: nonce,
            applicationSupportURL: support
        ).ready)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(!ReplacementHealthService.continuousAgentJob(
            label: "test.job",
            expectedExecutableURL: executable,
            expectedNonce: nonce,
            applicationSupportURL: support
        ).ready)
    }

    @Test
    func upgradeLockIsExclusiveAndReleasesWithoutStaleOwnership() throws {
        let support = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        var first: UpgradeExecutionLock? = try UpgradeExecutionLock(supportURL: support)
        #expect(throws: UpgradeExecutionLockError.self) {
            _ = try UpgradeExecutionLock(supportURL: support)
        }
        first = nil
        let second = try UpgradeExecutionLock(supportURL: support)
        _ = second
        _ = first
    }

    @Test
    func upgradeLockRejectsSymlinkedStateDirectory() throws {
        let root = try temporaryDirectory()
        let target = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let support = root.appending(path: "Switchboard")
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: target)
        #expect(throws: UpgradeExecutionLockError.self) {
            _ = try UpgradeExecutionLock(supportURL: support)
        }
    }

    private func currentExecutableURL() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let path = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: pointer.count) {
                String(decodingCString: $0, as: UTF8.self)
            }
        }
        return URL(fileURLWithPath: path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "switchboard-upgrade-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
