import Foundation
import Darwin
import Testing
@testable import Switchboard

struct UpdateInstallerTests {
    @Test
    func installedBundleInfoReadsFreshPlistAfterReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "switchboard-bundle-info-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Switchboard.app", isDirectory: true)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: infoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        func writeVersion(_ version: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "com.ivogundlach.switchboard",
                    "CFBundleShortVersionString": version,
                ],
                format: .xml,
                options: 0
            )
            try data.write(to: infoURL, options: .atomic)
        }
        let fileSystem = LocalUpdateInstallerFileSystem()
        try writeVersion("0.1.0")
        #expect(try fileSystem.bundleInfo(at: app).version == "0.1.0")
        try writeVersion("0.2.3")
        #expect(try fileSystem.bundleInfo(at: app).version == "0.2.3")
    }

    @Test
    func emptyCurrentBundleTrustAnchorFailsClosed() {
        #expect(throws: UpdateInstallerError.self) {
            try UpdateTrustAnchor(currentBundle: Bundle.main)
        }
    }

    @Test
    func targetOverrideIsRejectedAndCanonicalValuesCannotBeChanged() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        #expect(throws: UpdateInstallerError.self) {
            try UpdateInstallPlan(
                expectedVersion: "1.0.0",
                trustAnchor: anchor,
                targetURL: URL(fileURLWithPath: "/tmp/Other.app")
            )
        }
        let plan = try UpdateInstallPlan(expectedVersion: "1.0.0", trustAnchor: anchor)
        #expect(plan.targetURL.path == URL(fileURLWithPath: "/Applications/Switchboard.app").path)
        #expect(plan.expectedBundleIdentifier == "com.ivogundlach.switchboard")
    }

    @Test
    func pathPolicyRejectsTraversalAndSymlinks() throws {
        let mountRoot = URL(fileURLWithPath: "/private/tmp/update-mount")
        let candidate = mountRoot.appendingPathComponent("Switchboard.app", isDirectory: true)
        let fileSystem = FixtureFileSystem(
            directories: [mountRoot, candidate],
            children: [mountRoot: [candidate]]
        )
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        #expect(throws: UpdateInstallerError.self) {
            try policy.candidateURL(under: URL(fileURLWithPath: "/private/tmp/update-mount/../update-mount"))
        }

        let symlinkFileSystem = FixtureFileSystem(
            metadata: [
                mountRoot.path: UpdatePathMetadata(exists: true, isDirectory: true),
                candidate.path: UpdatePathMetadata(exists: true, isDirectory: true, isSymbolicLink: true),
            ],
            children: [mountRoot: [candidate]]
        )
        #expect(throws: UpdateInstallerError.self) {
            try UpdatePathPolicy(fileSystem: symlinkFileSystem).candidateURL(under: mountRoot)
        }
    }

    @Test
    func candidateMustBeExactlyOneAppUnderMountRoot() throws {
        let root = URL(fileURLWithPath: "/private/tmp/mount")
        let first = root.appendingPathComponent("Switchboard.app", isDirectory: true)
        let nested = root.appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("Switchboard.app", isDirectory: true)
        let fileSystem = FixtureFileSystem(
            directories: [root, first, nested.deletingLastPathComponent(), nested],
            children: [
                root: [first, nested.deletingLastPathComponent()],
                nested.deletingLastPathComponent(): [nested],
            ]
        )
        #expect(throws: UpdateInstallerError.self) {
            try UpdatePathPolicy(fileSystem: fileSystem).candidateURL(under: root)
        }
    }

    @Test
    func stagingBackupAndRecoveryPathsStayInTheirRequiredRoots() throws {
        let appSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        let fileSystem = FixtureFileSystem(metadata: [
            appSupport.path: UpdatePathMetadata(exists: true, isDirectory: true, posixPermissions: 0o700),
        ])
        let policy = UpdatePathPolicy(fileSystem: fileSystem)
        let transaction = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let staging = try policy.stagingURL(for: transaction)
        let backup = try policy.backupURL(for: transaction)
        #expect(staging.deletingLastPathComponent() == URL(fileURLWithPath: "/Applications"))
        #expect(backup.deletingLastPathComponent() == URL(fileURLWithPath: "/Applications"))
        #expect(throws: UpdateInstallerError.self) {
            try policy.validateStagingURL(URL(fileURLWithPath: "/Applications/../tmp/staging"))
        }
        #expect(throws: UpdateInstallerError.self) {
            try policy.validateStagingURL(URL(fileURLWithPath: "/Applications/other-sibling"))
        }

        let recovery = try policy.recoveryURL(for: transaction, under: appSupport)
        #expect(recovery.path.hasPrefix(appSupport.path + "/"))
        #expect(throws: UpdateInstallerError.self) {
            try policy.validateRecoveryURL(
                URL(fileURLWithPath: "/Users/test/Library/Application Support/../outside"),
                under: appSupport
            )
        }
        let permissive = FixtureFileSystem(metadata: [
            appSupport.path: UpdatePathMetadata(exists: true, isDirectory: true, posixPermissions: 0o755),
        ])
        #expect(throws: UpdateInstallerError.self) {
            try UpdatePathPolicy(fileSystem: permissive).recoveryURL(for: transaction, under: appSupport)
        }
    }

    @Test
    func canonicalTargetSymlinkIsRejected() {
        let target = UpdateInstallerConstants.canonicalTargetURL
        let fileSystem = FixtureFileSystem(metadata: [
            target.path: UpdatePathMetadata(exists: true, isDirectory: true, isSymbolicLink: true),
        ])
        #expect(throws: UpdateInstallerError.self) {
            try UpdatePathPolicy(fileSystem: fileSystem).validateCanonicalTarget()
        }
    }

    @Test
    func candidateValidatorRequiresEveryIndependentTrustCheck() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let root = URL(fileURLWithPath: "/private/tmp/mount")
        let candidate = root.appendingPathComponent("Switchboard.app", isDirectory: true)
        let info = UpdateBundleInfo(
            bundleIdentifier: "com.ivogundlach.switchboard",
            version: "2.0.0",
            architectures: []
        )
        let fileSystem = FixtureFileSystem(
            directories: [root, candidate],
            children: [root: [candidate]],
            bundleInfo: [candidate: info]
        )

        let goodRunner = FixtureCommandRunner()
        let validator = UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: goodRunner)
        #expect(try validator.validate(candidateUnder: root, plan: plan).teamIdentifier == "TEAM123")
        #expect(goodRunner.commands.contains {
            $0.executable == "/usr/bin/lipo" &&
            $0.arguments == ["-archs", candidate.appendingPathComponent("Contents/MacOS/Switchboard").path]
        })

        var wrongInfo = info
        wrongInfo = UpdateBundleInfo(bundleIdentifier: "com.example.other", version: info.version, architectures: info.architectures)
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(
                fileSystem: fileSystem.replacing(bundleInfo: [candidate: wrongInfo]),
                commandRunner: goodRunner
            ).validate(candidateUnder: root, plan: plan)
        }

        wrongInfo = UpdateBundleInfo(bundleIdentifier: info.bundleIdentifier, version: "9.9.9", architectures: info.architectures)
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(
                fileSystem: fileSystem.replacing(bundleInfo: [candidate: wrongInfo]),
                commandRunner: goodRunner
            ).validate(candidateUnder: root, plan: plan)
        }

        let noArm64 = FixtureCommandRunner(architectures: "x86_64")
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: noArm64)
                .validate(candidateUnder: root, plan: plan)
        }

        let wrongTeam = FixtureCommandRunner(teamOutput: "TeamIdentifier=OTHER")
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: wrongTeam)
                .validate(candidateUnder: root, plan: plan)
        }

        let wrongCertificate = FixtureCommandRunner(requirement: "designated => anchor apple generic")
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: wrongCertificate)
                .validate(candidateUnder: root, plan: plan)
        }

        let failedRequirementCommand = FixtureCommandRunner(
            requirement: "designated => anchor apple generic and certificate leaf[1.2.840.113635.100.6.1.13] exists",
            requirementResult: UpdateCommandResult(status: 1, stderr: "codesign failed")
        )
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: failedRequirementCommand)
                .validate(candidateUnder: root, plan: plan)
        }

        let gatekeeperRejected = FixtureCommandRunner(gatekeeper: UpdateCommandResult(status: 1, stderr: "rejected"))
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: gatekeeperRejected)
                .validate(candidateUnder: root, plan: plan)
        }

        let signatureRejected = FixtureCommandRunner(signature: UpdateCommandResult(status: 1, stderr: "not signed"))
        #expect(throws: UpdateInstallerError.self) {
            try UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: signatureRejected)
                .validate(candidateUnder: root, plan: plan)
        }
    }

    @Test
    func everyLegalStateTransitionAndIllegalSkipIsEnforced() throws {
        let identity = ParentIdentity(pid: 100, executableURL: URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard"), startTime: Date(timeIntervalSince1970: 10))
        var record = UpdateInstallRecord(parentIdentity: identity, now: Date(timeIntervalSince1970: 1))
        let ordered: [UpdateInstallState] = [
            .hashVerified, .mounted, .candidateVerified, .staged,
            .recoveryVerified, .replacing, .installedVerified, .completed,
        ]
        for state in ordered {
            try record.transition(to: state, note: state.rawValue)
        }
        #expect(record.state == .completed)
        #expect(record.events.map(\.state) == [.downloaded] + ordered)

        var fresh = UpdateInstallRecord(parentIdentity: identity)
        #expect(throws: UpdateInstallerError.self) {
            try fresh.transition(to: .mounted, note: "skip hash")
        }
        #expect(!UpdateInstallState.completed.canTransition(to: .failed))
        #expect(UpdateInstallState.replacing.canTransition(to: .rollingBack))
        #expect(UpdateInstallState.rollingBack.canTransition(to: .rolledBack))
        #expect(!UpdateInstallState.rolledBack.canTransition(to: .completed))
    }

    @Test
    func interruptionDetectionCoversActiveAndRollbackBoundaries() throws {
        let identity = ParentIdentity(pid: 101, executableURL: URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard"), startTime: Date(timeIntervalSince1970: 20))
        var record = UpdateInstallRecord(parentIdentity: identity)
        #expect(record.interruption() == .unfinished(.downloaded))
        try record.transition(to: .hashVerified, note: "hash")
        #expect(record.interruption() == .unfinished(.hashVerified))
        try record.transition(to: .mounted, note: "mount")
        #expect(record.state.needsRecoveryAfterInterruption)
        try record.transition(to: .candidateVerified, note: "candidate")
        try record.transition(to: .staged, note: "stage")
        try record.transition(to: .recoveryVerified, note: "recovery")
        try record.transition(to: .replacing, note: "replace")
        #expect(record.interruption() == .unfinished(.replacing))
        try record.transition(to: .rollingBack, note: "rollback")
        #expect(record.interruption() == .unfinished(.rollingBack))
        try record.transition(to: .rolledBack, note: "restored")
        #expect(record.interruption() == .none)
    }

    @Test
    func parentIdentityUsesPIDExecutableAndStartTimeToRejectReuse() throws {
        let executable = URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard")
        let identity = ParentIdentity(pid: 321, executableURL: executable, startTime: Date(timeIntervalSince1970: 30))
        let same = ParentIdentity(pid: 321, executableURL: executable, startTime: Date(timeIntervalSince1970: 30))
        let reusedPID = ParentIdentity(pid: 321, executableURL: URL(fileURLWithPath: "/tmp/other"), startTime: Date(timeIntervalSince1970: 31))
        #expect(identity.matches(same))
        #expect(!identity.matches(reusedPID))

        let record = UpdateInstallRecord(parentIdentity: identity)
        #expect(record.interruption(observedParent: reusedPID) == .parentIdentityChanged)
        #expect(throws: UpdateInstallerError.self) {
            try record.verifyParent(reusedPID)
        }
    }

    @Test
    func transactionPersistsIntentBeforeEveryExternalEffectAndCompletes() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let root = URL(fileURLWithPath: "/private/tmp/mount")
        let candidate = root.appendingPathComponent("Switchboard.app", isDirectory: true)
        let fileSystem = FixtureFileSystem(
            directories: [root, candidate],
            children: [root: [candidate]],
            bundleInfo: [candidate: UpdateBundleInfo(bundleIdentifier: plan.expectedBundleIdentifier, version: plan.expectedVersion)]
        )
        let effects = FixtureEffects(mountRoot: root)
        let store = FixtureRecordStore()
        let transaction = UpdateInstallerTransaction(
            effects: effects,
            store: store,
            validator: UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: FixtureCommandRunner())
        )
        let identity = ParentIdentity(pid: 500, executableURL: URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard"), startTime: Date(timeIntervalSince1970: 50))
        let layout = UpdateInstallLayout(
            targetURL: UpdateInstallerConstants.canonicalTargetURL,
            stagingURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.update-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            backupURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.backup-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            recoveryURL: URL(fileURLWithPath: "/private/tmp/recovery/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )

        let record = try transaction.execute(
            plan: plan,
            imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
            layout: layout,
            parentIdentity: identity,
            hashVerified: true
        )

        #expect(record.state == .completed)
        #expect(record.pendingIntent == nil)
        #expect(effects.calls == ["mount", "stage", "backup", "unmount", "replace", "verify"])
        #expect(store.records.contains { $0.pendingIntent?.operation == "mount-read-only" && $0.state == .mounted })
        #expect(store.records.contains { $0.pendingIntent?.operation == "stage-candidate" && $0.state == .staged })
        #expect(store.records.contains { $0.pendingIntent?.operation == "create-exact-recovery-backup" && $0.state == .recoveryVerified })
        #expect(store.records.contains { $0.pendingIntent?.operation == "atomic-replace" && $0.state == .replacing })
        #expect(store.records.contains { $0.pendingIntent?.operation == "verify-installed" && $0.state == .installedVerified })
    }

    @Test
    func transactionRollsBackAfterReplacementFailureAndPersistsRollbackIntent() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let root = URL(fileURLWithPath: "/private/tmp/mount")
        let candidate = root.appendingPathComponent("Switchboard.app", isDirectory: true)
        let fileSystem = FixtureFileSystem(
            directories: [root, candidate],
            children: [root: [candidate]],
            bundleInfo: [candidate: UpdateBundleInfo(bundleIdentifier: plan.expectedBundleIdentifier, version: plan.expectedVersion)]
        )
        let effects = FixtureEffects(mountRoot: root, failure: "replace")
        let store = FixtureRecordStore()
        let transaction = UpdateInstallerTransaction(
            effects: effects,
            store: store,
            validator: UpdateCandidateValidator(fileSystem: fileSystem, commandRunner: FixtureCommandRunner())
        )
        let identity = ParentIdentity(pid: 501, executableURL: URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard"), startTime: Date(timeIntervalSince1970: 51))
        let layout = UpdateInstallLayout(
            targetURL: UpdateInstallerConstants.canonicalTargetURL,
            stagingURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.update-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            backupURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.backup-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            recoveryURL: URL(fileURLWithPath: "/private/tmp/recovery/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )

        #expect(throws: Error.self) {
            try transaction.execute(
                plan: plan,
                imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
                layout: layout,
                parentIdentity: identity,
                hashVerified: true
            )
        }
        #expect(effects.calls == ["mount", "stage", "backup", "unmount", "replace", "rollback"])
        #expect(store.records.contains { $0.pendingIntent?.operation == "rollback" && $0.state == .rollingBack })
        #expect(store.records.last?.state == .rolledBack)
    }

    @Test
    func candidateValidationFailureUnmountsWithoutRequiringABackup() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let root = URL(fileURLWithPath: "/private/tmp/mount")
        let candidate = root.appendingPathComponent("Switchboard.app", isDirectory: true)
        let fileSystem = FixtureFileSystem(
            directories: [root, candidate],
            children: [root: [candidate]],
            bundleInfo: [candidate: UpdateBundleInfo(
                bundleIdentifier: plan.expectedBundleIdentifier,
                version: plan.expectedVersion
            )]
        )
        let effects = FixtureEffects(mountRoot: root)
        let store = FixtureRecordStore()
        let transaction = UpdateInstallerTransaction(
            effects: effects,
            store: store,
            validator: UpdateCandidateValidator(
                fileSystem: fileSystem,
                commandRunner: FixtureCommandRunner(architectures: "x86_64")
            )
        )
        let identity = ParentIdentity(
            pid: 509,
            executableURL: UpdateInstallerConstants.canonicalExecutableURL,
            startTime: Date(timeIntervalSince1970: 59)
        )
        let transactionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let layout = UpdateInstallLayout(
            targetURL: UpdateInstallerConstants.canonicalTargetURL,
            stagingURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.update-\(transactionID.uuidString)"),
            backupURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.backup-\(transactionID.uuidString)"),
            recoveryURL: URL(fileURLWithPath: "/private/tmp/recovery/\(transactionID.uuidString)")
        )

        #expect(throws: UpdateInstallerError.self) {
            try transaction.execute(
                plan: plan,
                imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
                layout: layout,
                parentIdentity: identity,
                hashVerified: true
            )
        }
        #expect(effects.calls == ["mount", "unmount"])
        #expect(store.records.last?.state == .rolledBack)
    }

    @Test
    func recoveryDirectoryPreparationNormalizesOwnedParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "switchboard-update-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let switchboard = root.appendingPathComponent("Switchboard", isDirectory: true)
        let recovery = switchboard.appendingPathComponent("UpdateRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recovery.path)

        try UpdateRecoveryDirectory.prepare(applicationSupportURL: root)

        let attributes = try FileManager.default.attributesOfItem(atPath: recovery.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test
    func transactionRejectsParentReuseBeforeAnyEffect() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let effects = FixtureEffects(mountRoot: URL(fileURLWithPath: "/private/tmp/mount"))
        let store = FixtureRecordStore()
        let transaction = UpdateInstallerTransaction(
            effects: effects,
            store: store,
            validator: UpdateCandidateValidator(fileSystem: FixtureFileSystem(), commandRunner: FixtureCommandRunner())
        )
        let recorded = ParentIdentity(pid: 502, executableURL: URL(fileURLWithPath: "/Applications/Switchboard.app/Contents/MacOS/Switchboard"), startTime: Date(timeIntervalSince1970: 52))
        let reused = ParentIdentity(pid: 502, executableURL: URL(fileURLWithPath: "/private/tmp/reused"), startTime: Date(timeIntervalSince1970: 53))
        let existing = UpdateInstallRecord(parentIdentity: recorded)
        let layout = UpdateInstallLayout(
            targetURL: UpdateInstallerConstants.canonicalTargetURL,
            stagingURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.update-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            backupURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.backup-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            recoveryURL: URL(fileURLWithPath: "/private/tmp/recovery/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        #expect(throws: UpdateInstallerError.self) {
            try transaction.execute(
                plan: plan,
                imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
                layout: layout,
                parentIdentity: reused,
                existingRecord: existing
            )
        }
        #expect(effects.calls.isEmpty)
    }

    @Test
    func transactionRequiresIndependentHashVerificationAndFixedParentExecutable() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let effects = FixtureEffects(mountRoot: URL(fileURLWithPath: "/private/tmp/mount"))
        let store = FixtureRecordStore()
        let transaction = UpdateInstallerTransaction(
            effects: effects,
            store: store,
            validator: UpdateCandidateValidator(fileSystem: FixtureFileSystem(), commandRunner: FixtureCommandRunner())
        )
        let identity = ParentIdentity(pid: 503, executableURL: UpdateInstallerConstants.canonicalExecutableURL, startTime: Date(timeIntervalSince1970: 54))
        let layout = UpdateInstallLayout(
            targetURL: UpdateInstallerConstants.canonicalTargetURL,
            stagingURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.update-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            backupURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.backup-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            recoveryURL: URL(fileURLWithPath: "/private/tmp/recovery/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        #expect(throws: UpdateInstallerError.self) {
            try transaction.execute(
                plan: plan,
                imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
                layout: layout,
                parentIdentity: identity
            )
        }
        #expect(effects.calls.isEmpty)

        let wrongExecutable = ParentIdentity(pid: 504, executableURL: URL(fileURLWithPath: "/private/tmp/not-switchboard"), startTime: Date(timeIntervalSince1970: 55))
        #expect(throws: UpdateInstallerError.self) {
            try transaction.execute(
                plan: plan,
                imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
                layout: layout,
                parentIdentity: wrongExecutable,
                hashVerified: true
            )
        }
        #expect(effects.calls.isEmpty)
    }

    @Test
    func transactionRecordMustMatchRecoveryLayoutIdentity() throws {
        let anchor = try UpdateTrustAnchor(testTeamIdentifier: "TEAM123")
        let plan = try UpdateInstallPlan(expectedVersion: "2.0.0", trustAnchor: anchor)
        let effects = FixtureEffects(mountRoot: URL(fileURLWithPath: "/private/tmp/mount"))
        let transaction = UpdateInstallerTransaction(
            effects: effects,
            store: FixtureRecordStore(),
            validator: UpdateCandidateValidator(
                fileSystem: FixtureFileSystem(),
                commandRunner: FixtureCommandRunner()
            )
        )
        let parent = ParentIdentity(
            pid: 505,
            executableURL: UpdateInstallerConstants.canonicalExecutableURL,
            startTime: Date(timeIntervalSince1970: 56)
        )
        let layout = UpdateInstallLayout(
            targetURL: UpdateInstallerConstants.canonicalTargetURL,
            stagingURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.update-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            backupURL: URL(fileURLWithPath: "/Applications/.Switchboard.app.backup-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            recoveryURL: URL(fileURLWithPath: "/private/tmp/recovery/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let different = UpdateInstallRecord(
            transactionID: UUID(),
            parentIdentity: parent
        )
        #expect(throws: UpdateInstallerError.transactionIdentityMismatch) {
            try transaction.execute(
                plan: plan,
                imageURL: URL(fileURLWithPath: "/private/tmp/update.dmg"),
                layout: layout,
                parentIdentity: parent,
                existingRecord: different,
                hashVerified: true
            )
        }
        #expect(effects.calls.isEmpty)
    }

    @Test
    func crossLaunchRecoveryRollsBackInterruptedReplacement() throws {
        let applicationSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        let transactionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let root = applicationSupport
            .appendingPathComponent("Switchboard", isDirectory: true)
            .appendingPathComponent(UpdateInstallerConstants.recoveryDirectoryName, isDirectory: true)
        let recoveryURL = root.appendingPathComponent(transactionID.uuidString, isDirectory: true)
        let identity = ParentIdentity(
            pid: 700,
            executableURL: UpdateInstallerConstants.canonicalExecutableURL,
            startTime: Date(timeIntervalSince1970: 70)
        )
        var interrupted = UpdateInstallRecord(transactionID: transactionID, parentIdentity: identity)
        try interrupted.transition(to: .hashVerified, note: "hash")
        try interrupted.transition(to: .mounted, note: "mount")
        try interrupted.transition(to: .candidateVerified, note: "candidate")
        try interrupted.transition(to: .staged, note: "stage")
        try interrupted.transition(to: .recoveryVerified, note: "backup")
        try interrupted.transition(to: .replacing, note: "replace")

        let fileSystem = recoveryFileSystem(
            applicationSupport: applicationSupport,
            recoveryRoot: root,
            transactionDirectories: [recoveryURL]
        )
        let store = FixtureRecordStore(initial: interrupted)
        let effects = FixtureEffects(mountRoot: URL(fileURLWithPath: "/private/tmp/mount"))
        let recovery = UpdateInstallRecovery(
            applicationSupportURL: applicationSupport,
            effects: effects,
            fileSystem: fileSystem,
            storeFactory: { _, _, _ in store }
        )

        let resumed = try recovery.resume()

        #expect(resumed.count == 1)
        #expect(resumed[0].state == .rolledBack)
        #expect(resumed[0].pendingIntent == nil)
        #expect(effects.calls == ["rollback"])
        #expect(store.records.contains { $0.state == .rollingBack && $0.pendingIntent?.operation == "rollback" })
        #expect(store.records.last?.state == .rolledBack)
    }

    @Test
    func crossLaunchRecoveryUnmountsAnInterruptedMountedImageBeforeFailingTransaction() throws {
        let applicationSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        let transactionID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let root = applicationSupport
            .appendingPathComponent("Switchboard", isDirectory: true)
            .appendingPathComponent(UpdateInstallerConstants.recoveryDirectoryName, isDirectory: true)
        let recoveryURL = root.appendingPathComponent(transactionID.uuidString, isDirectory: true)
        let identity = ParentIdentity(
            pid: 701,
            executableURL: UpdateInstallerConstants.canonicalExecutableURL,
            startTime: Date(timeIntervalSince1970: 71)
        )
        var interrupted = UpdateInstallRecord(transactionID: transactionID, parentIdentity: identity)
        try interrupted.transition(to: .hashVerified, note: "hash")
        try interrupted.transition(to: .mounted, note: "mount")
        let mountRoot = URL(fileURLWithPath: "/private/tmp/mounted-image")
        interrupted.setMountedRoot(mountRoot)

        let fileSystem = recoveryFileSystem(
            applicationSupport: applicationSupport,
            recoveryRoot: root,
            transactionDirectories: [recoveryURL]
        )
        let store = FixtureRecordStore(initial: interrupted)
        let effects = FixtureEffects(mountRoot: mountRoot)
        let recovery = UpdateInstallRecovery(
            applicationSupportURL: applicationSupport,
            effects: effects,
            fileSystem: fileSystem,
            storeFactory: { _, _, _ in store }
        )

        let resumed = try recovery.resume()

        #expect(resumed.count == 1)
        #expect(resumed[0].state == .failed)
        #expect(resumed[0].mountedRoot == nil)
        #expect(effects.calls == ["unmount"])
        #expect(store.records.contains { $0.state == .rollingBack && $0.pendingIntent?.operation == "rollback" })
        #expect(store.records.contains { $0.pendingIntent?.operation == "unmount-read-only" })
    }

    @Test
    func recoveryRejectsMalformedSymlinkAndForeignDirectories() throws {
        let applicationSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        let root = applicationSupport
            .appendingPathComponent("Switchboard", isDirectory: true)
            .appendingPathComponent(UpdateInstallerConstants.recoveryDirectoryName, isDirectory: true)

        let malformed = root.appendingPathComponent("not-a-transaction", isDirectory: true)
        let malformedFS = recoveryFileSystem(
            applicationSupport: applicationSupport,
            recoveryRoot: root,
            transactionDirectories: [malformed]
        )
        let effects = FixtureEffects(mountRoot: URL(fileURLWithPath: "/private/tmp/mount"))
        let malformedRecovery = UpdateInstallRecovery(
            applicationSupportURL: applicationSupport,
            effects: effects,
            fileSystem: malformedFS,
            storeFactory: { _, _, _ in FixtureRecordStore() }
        )
        #expect(throws: UpdateInstallerError.transactionRecordPathInvalid) {
            try malformedRecovery.discover()
        }

        let symlink = root.appendingPathComponent("CCCCCCCC-DDDD-EEEE-FFFF-000000000000", isDirectory: true)
        let symlinkFS = recoveryFileSystem(
            applicationSupport: applicationSupport,
            recoveryRoot: root,
            transactionDirectories: [symlink],
            symbolicLinks: [symlink]
        )
        let symlinkRecovery = UpdateInstallRecovery(
            applicationSupportURL: applicationSupport,
            effects: effects,
            fileSystem: symlinkFS,
            storeFactory: { _, _, _ in FixtureRecordStore() }
        )
        #expect(throws: UpdateInstallerError.self) {
            try symlinkRecovery.discover()
        }

        let foreign = root.appendingPathComponent("DDDDDDDD-EEEE-FFFF-0000-111111111111", isDirectory: true)
        let foreignFS = recoveryFileSystem(
            applicationSupport: applicationSupport,
            recoveryRoot: root,
            transactionDirectories: [foreign],
            directoryPermissions: 0o755
        )
        let foreignRecovery = UpdateInstallRecovery(
            applicationSupportURL: applicationSupport,
            effects: effects,
            fileSystem: foreignFS,
            storeFactory: { _, _, _ in FixtureRecordStore() }
        )
        #expect(throws: UpdateInstallerError.self) {
            try foreignRecovery.discover()
        }
    }

    private func recoveryFileSystem(
        applicationSupport: URL,
        recoveryRoot: URL,
        transactionDirectories: [URL],
        symbolicLinks: Set<URL> = [],
        directoryPermissions: UInt16 = 0o700
    ) -> FixtureFileSystem {
        let owner = UInt32(getuid())
        var metadata: [String: UpdatePathMetadata] = [
            applicationSupport.path: UpdatePathMetadata(
                exists: true,
                isDirectory: true,
                posixPermissions: 0o700,
                ownerUserID: owner
            ),
            recoveryRoot.path: UpdatePathMetadata(
                exists: true,
                isDirectory: true,
                posixPermissions: 0o700,
                ownerUserID: owner
            ),
        ]
        let switchboard = recoveryRoot.deletingLastPathComponent()
        metadata[switchboard.path] = UpdatePathMetadata(
            exists: true,
            isDirectory: true,
            posixPermissions: 0o700,
            ownerUserID: owner
        )
        for directory in transactionDirectories {
            metadata[directory.path] = UpdatePathMetadata(
                exists: true,
                isDirectory: true,
                isSymbolicLink: symbolicLinks.contains(directory),
                posixPermissions: directoryPermissions,
                ownerUserID: owner
            )
            let record = directory.appendingPathComponent("transaction.json")
            metadata[record.path] = UpdatePathMetadata(
                exists: true,
                isDirectory: false,
                posixPermissions: 0o600,
                ownerUserID: owner
            )
        }
        var children: [URL: [URL]] = [
            recoveryRoot: transactionDirectories,
            switchboard: [recoveryRoot],
        ]
        for directory in transactionDirectories {
            children[directory] = [directory.appendingPathComponent("transaction.json")]
        }
        return FixtureFileSystem(metadata: metadata, children: children)
    }
}

private struct FixtureFileSystem: UpdateInstallerFileSystem {
    private let metadataByPath: [String: UpdatePathMetadata]
    private let childrenByPath: [String: [URL]]
    private let bundleInfoByPath: [String: UpdateBundleInfo]

    init(
        metadata: [String: UpdatePathMetadata] = [:],
        directories: Set<URL> = [],
        children: [URL: [URL]] = [:],
        bundleInfo: [URL: UpdateBundleInfo] = [:]
    ) {
        var metadataByPath = metadata
        for directory in directories {
            metadataByPath[directory.path] = metadataByPath[directory.path] ?? UpdatePathMetadata(exists: true, isDirectory: true)
        }
        self.metadataByPath = metadataByPath
        self.childrenByPath = Dictionary(uniqueKeysWithValues: children.map { ($0.key.path, $0.value) })
        self.bundleInfoByPath = Dictionary(uniqueKeysWithValues: bundleInfo.map { ($0.key.path, $0.value) })
    }

    func replacing(bundleInfo: [URL: UpdateBundleInfo]) -> FixtureFileSystem {
        FixtureFileSystem(
            metadata: metadataByPath,
            children: Dictionary(uniqueKeysWithValues: childrenByPath.map { (URL(fileURLWithPath: $0.key), $0.value) }),
            bundleInfo: bundleInfo
        )
    }

    func metadata(at url: URL) throws -> UpdatePathMetadata {
        metadataByPath[url.path] ?? UpdatePathMetadata(exists: false)
    }

    func children(of url: URL) throws -> [URL] {
        childrenByPath[url.path] ?? []
    }

    func bundleInfo(at url: URL) throws -> UpdateBundleInfo {
        bundleInfoByPath[url.path] ?? UpdateBundleInfo(bundleIdentifier: nil, version: nil)
    }
}

private final class FixtureCommandRunner: UpdateCommandRunner {
    private(set) var commands: [UpdateCommand] = []
    let architectures: String
    let signature: UpdateCommandResult
    let teamOutput: String
    let requirement: String
    let requirementResult: UpdateCommandResult
    let gatekeeper: UpdateCommandResult

    init(
        architectures: String = "arm64",
        signature: UpdateCommandResult = UpdateCommandResult(status: 0),
        teamOutput: String = "TeamIdentifier=TEAM123",
        requirement: String = "designated => anchor apple generic and certificate leaf[1.2.840.113635.100.6.1.13] exists",
        requirementResult: UpdateCommandResult = UpdateCommandResult(status: 0),
        gatekeeper: UpdateCommandResult = UpdateCommandResult(status: 0, stdout: "accepted")
    ) {
        self.architectures = architectures
        self.signature = signature
        self.teamOutput = teamOutput
        self.requirement = requirement
        self.requirementResult = requirementResult
        self.gatekeeper = gatekeeper
    }

    func run(_ command: UpdateCommand) throws -> UpdateCommandResult {
        commands.append(command)
        if command.executable == "/usr/bin/lipo" { return UpdateCommandResult(status: 0, stdout: architectures) }
        if command.executable == "/usr/sbin/spctl" { return gatekeeper }
        if command.arguments.contains("--verify") { return signature }
        if command.arguments.contains("--requirements") {
            return UpdateCommandResult(status: requirementResult.status, stdout: requirement, stderr: requirementResult.stderr)
        }
        return UpdateCommandResult(status: 0, stderr: teamOutput)
    }
}

private final class FixtureRecordStore: UpdateInstallRecordStore {
    private(set) var records: [UpdateInstallRecord] = []

    init(initial: UpdateInstallRecord? = nil) {
        if let initial {
            records = [initial]
        }
    }

    func save(_ record: UpdateInstallRecord) throws {
        records.append(record)
    }

    func load() throws -> UpdateInstallRecord? {
        records.last
    }
}

private final class FixtureEffects: UpdateInstallerEffects {
    let mountRoot: URL
    let failure: String?
    private(set) var calls: [String] = []

    init(mountRoot: URL, failure: String? = nil) {
        self.mountRoot = mountRoot
        self.failure = failure
    }

    func mountReadOnly(imageURL: URL) throws -> UpdateMount {
        calls.append("mount")
        try failIfNeeded("mount")
        return UpdateMount(mountRoot: mountRoot)
    }

    func stage(candidateURL: URL, stagingURL: URL) throws {
        calls.append("stage")
        try failIfNeeded("stage")
    }

    func createRecoveryBackup(targetURL: URL, backupURL: URL) throws {
        calls.append("backup")
        try failIfNeeded("backup")
    }

    func atomicReplace(stagingURL: URL, targetURL: URL) throws {
        calls.append("replace")
        try failIfNeeded("replace")
    }

    func verifyInstalled(targetURL: URL, plan: UpdateInstallPlan) throws {
        calls.append("verify")
        try failIfNeeded("verify")
    }

    func rollback(targetURL: URL, backupURL: URL) throws {
        calls.append("rollback")
        try failIfNeeded("rollback")
    }

    func unmount(mountRoot: URL) throws {
        calls.append("unmount")
        try failIfNeeded("unmount")
    }

    private func failIfNeeded(_ operation: String) throws {
        if failure == operation {
            throw UpdateInstallerError.commandFailed(operation, 1, "fixture failure")
        }
    }
}
