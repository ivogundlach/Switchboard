import Foundation
import Testing
@testable import Switchboard

struct UpgradeMigrationContractTests {
    private let moduleIDs: Set<String> = [
        "desktop.warm-corners", "desktop.kinetics", "desktop.audio-guard", "desktop.quit-on-close",
        "desktop.smart-wake", "desktop.brightness", "mail.assistant", "files.copy-path",
        "files.auto-install-dmg", "links.copy-safari-url", "connectors.local-read", "systems.memory",
        "systems.codex-improvement", "systems.repository-release", "systems.notebooklm",
        "systems.backup-audit", "systems.advanced-commands"
    ]

    @Test
    func liveResourceHasAllManifestModulesAndPassesValidation() throws {
        let contractURL = projectURL().appending(path: "Sources/Switchboard/Resources/UpgradeMigrationContract.json")
        let contract = try UpgradeMigrationContract.load(from: contractURL, moduleIDs: moduleIDs)
        #expect(contract.schemaVersion == 1)
        #expect(Set(contract.modules.map(\.moduleID)) == moduleIDs)
        #expect(contract.modules.count == 17)
    }

    @Test
    func rejectsWrongSchemaVersion() {
        var contract = fixture()
        contract = UpgradeMigrationContract(schemaVersion: 2, modules: contract.modules)
        expectValidationFailure(contract)
    }

    @Test
    func rejectsDuplicateMissingAndUnknownModuleIDs() {
        let module = fixture().modules[0]
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module, module]), ids: [module.moduleID])
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: [module.moduleID, "missing"])
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: ["different"])
    }

    @Test
    func rejectsDuplicateComponentIDs() {
        let component = UpgradeLegacyComponent(id: "same", displayName: "One", kind: .command, disposition: .retain)
        let module = UpgradeMigrationModule(moduleID: "m", settingsPolicy: .sharedCanonical, replacementHealth: .verified, legacyComponents: [component, component], permissions: [])
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: ["m"])
    }

    @Test
    func rejectsIncompleteMigratedApps() {
        let app = UpgradeLegacyComponent(id: "app", displayName: "App", kind: .appBundle, disposition: .migrate, canonicalPath: "/Applications/App.app", bundleID: nil, executableName: "App")
        expectValidationFailure(contract(with: [app]))
    }

    @Test
    func rejectsMigratedSchedulersWithoutLabels() {
        let launchAgent = UpgradeLegacyComponent(id: "agent", displayName: "Agent", kind: .launchAgent, disposition: .migrate)
        let cron = UpgradeLegacyComponent(id: "cron", displayName: "Cron", kind: .cron, disposition: .migrate)
        expectValidationFailure(contract(with: [launchAgent]))
        expectValidationFailure(contract(with: [cron]))
    }

    @Test
    func rejectsUnsafeAppBundlePaths() {
        for path in ["/tmp/App.app", "/Applications/Nested/App.app", "/Applications/../App.app", "/Applications/.app"] {
            let app = UpgradeLegacyComponent(id: "app", displayName: "App", kind: .appBundle, disposition: .retain, canonicalPath: path)
            expectValidationFailure(contract(with: [app]))
        }
    }

    @Test
    func rejectsMigrationWhenReplacementIsUnverified() {
        let component = UpgradeLegacyComponent(id: "command", displayName: "Command", kind: .command, disposition: .migrate)
        let module = UpgradeMigrationModule(moduleID: "m", settingsPolicy: .legacyOnce, replacementHealth: .unverified, legacyComponents: [component], permissions: [])
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: ["m"])
    }

    @Test
    func rejectsDuplicatePermissionIDs() {
        let permission = permission(id: "same")
        let module = UpgradeMigrationModule(moduleID: "m", settingsPolicy: .sharedCanonical, replacementHealth: .verified, legacyComponents: [], permissions: [permission, permission])
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: ["m"])
    }

    @Test
    func rejectsAccessibilityAndFullDiskPermissionsWithoutSubjectPath() {
        for mechanism in [UpgradePermissionMechanism.accessibilityHelper, .fullDiskAccessHelper] {
            let module = UpgradeMigrationModule(moduleID: "m", settingsPolicy: .sharedCanonical, replacementHealth: .verified, legacyComponents: [], permissions: [permission(id: "p", mechanism: mechanism)])
            expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: ["m"])
        }
    }

    @Test
    func rejectsRuntimePromptWithoutTargetBundleID() {
        let module = UpgradeMigrationModule(moduleID: "m", settingsPolicy: .sharedCanonical, replacementHealth: .verified, legacyComponents: [], permissions: [permission(id: "p", mechanism: .runtimePrompt)])
        expectValidationFailure(UpgradeMigrationContract(schemaVersion: 1, modules: [module]), ids: ["m"])
    }

    private func fixture() -> UpgradeMigrationContract {
        UpgradeMigrationContract(
            schemaVersion: 1,
            modules: [UpgradeMigrationModule(moduleID: "m", settingsPolicy: .sharedCanonical, replacementHealth: .verified, legacyComponents: [], permissions: [])]
        )
    }

    private func contract(with components: [UpgradeLegacyComponent], health: UpgradeReplacementHealth = .verified) -> UpgradeMigrationContract {
        UpgradeMigrationContract(
            schemaVersion: 1,
            modules: [UpgradeMigrationModule(moduleID: "m", settingsPolicy: .legacyOnce, replacementHealth: health, legacyComponents: components, permissions: [])]
        )
    }

    private func permission(id: String, mechanism: UpgradePermissionMechanism = .accessibilityHelper) -> UpgradePermission {
        UpgradePermission(id: id, displayName: "Permission", subject: "Subject", mechanism: mechanism, detail: "Details")
    }

    private func expectValidationFailure(_ contract: UpgradeMigrationContract, ids: Set<String> = ["m"]) {
        #expect(throws: UpgradeMigrationContractValidationError.self) {
            try contract.validate(against: ids)
        }
    }

    private func projectURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
