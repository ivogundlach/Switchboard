import Testing
@testable import Switchboard

struct WarmCornersLiveMigrationTests {
    private let hash = String(repeating: "a", count: 64)

    @Test
    func preflightRequiresExactVersionCapabilityHashAndSafeState() throws {
        let safe = WarmCornersBridgeStatus(
            bridgeVersion: 1,
            capability: "switchboard-headless-migration-v1",
            login: "enabled",
            migrationLockPresent: false,
            settingsSHA256: hash,
            watcherProcessCount: 1
        )
        #expect(try WarmCornersLiveMigration.validatePreflightStatus(safe) == hash)

        for unsafe in [
            WarmCornersBridgeStatus(bridgeVersion: 2, capability: safe.capability, login: safe.login, migrationLockPresent: false, settingsSHA256: hash, watcherProcessCount: 1),
            WarmCornersBridgeStatus(bridgeVersion: 1, capability: "wrong", login: safe.login, migrationLockPresent: false, settingsSHA256: hash, watcherProcessCount: 1),
            WarmCornersBridgeStatus(bridgeVersion: 1, capability: safe.capability, login: "requiresApproval", migrationLockPresent: false, settingsSHA256: hash, watcherProcessCount: 1),
            WarmCornersBridgeStatus(bridgeVersion: 1, capability: safe.capability, login: safe.login, migrationLockPresent: true, settingsSHA256: hash, watcherProcessCount: 1),
            WarmCornersBridgeStatus(bridgeVersion: 1, capability: safe.capability, login: safe.login, migrationLockPresent: false, settingsSHA256: "bad", watcherProcessCount: 1),
            WarmCornersBridgeStatus(bridgeVersion: 1, capability: safe.capability, login: safe.login, migrationLockPresent: false, settingsSHA256: hash, watcherProcessCount: 2),
        ] {
            #expect(throws: WarmCornersLiveMigrationError.self) {
                try WarmCornersLiveMigration.validatePreflightStatus(unsafe)
            }
        }
    }

    @Test
    func committedHandoffRequiresPersistentLockNoWatcherAndDisabledLegacyLogin() throws {
        for login in ["notRegistered", "notFound"] {
            let safe = WarmCornersBridgeStatus(
                bridgeVersion: 1,
                capability: "switchboard-headless-migration-v1",
                login: login,
                migrationLockPresent: true,
                settingsSHA256: hash,
                watcherProcessCount: 0
            )
            try WarmCornersLiveMigration.validateStoppedStatus(safe, expectedHash: hash)
        }

        let unsafe = WarmCornersBridgeStatus(
            bridgeVersion: 1,
            capability: "switchboard-headless-migration-v1",
            login: "enabled",
            migrationLockPresent: true,
            settingsSHA256: hash,
            watcherProcessCount: 0
        )
        #expect(throws: WarmCornersLiveMigrationError.self) {
            try WarmCornersLiveMigration.validateStoppedStatus(unsafe, expectedHash: hash)
        }
    }
}
