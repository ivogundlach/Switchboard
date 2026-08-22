import Testing
@testable import Switchboard

struct UpgradeActivationPolicyTests {
    @Test
    func disabledModuleRunsTheFullEnablePath() {
        #expect(UpgradeActivationPolicy.action(isEnabled: false, ownershipReady: false) == .enable)
        #expect(UpgradeActivationPolicy.action(isEnabled: false, ownershipReady: true) == .enable)
    }

    @Test
    func enabledModuleRepairsMissingBundledOwnershipBeforeMigration() {
        #expect(UpgradeActivationPolicy.action(isEnabled: true, ownershipReady: false) == .repairOwnership)
    }

    @Test
    func enabledOwnedModuleOnlyMigratesLegacySchedulers() {
        #expect(UpgradeActivationPolicy.action(isEnabled: true, ownershipReady: true) == .migrateSchedulersOnly)
    }
}
