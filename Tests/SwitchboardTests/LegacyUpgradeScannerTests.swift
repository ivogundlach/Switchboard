import Foundation
import Testing
@testable import Switchboard

struct LegacyUpgradeScannerTests {
    @Test
    func activeKineticsKeepsLegacyEnabledStateAndSettings() throws {
        let (manifest, contract) = try resources()
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let snapshot = LegacyUpgradeScanSnapshot(
            existingPaths: ["/Applications/Kinetics.app"],
            runningAppPaths: ["/Applications/Kinetics.app"],
            loadedLaunchAgentLabels: [],
            cronText: "",
            defaultsDomains: [
                "com.ivogundlach.Kinetics": [
                    "desktopSwitching.enabled": true,
                    "desktopSwitching.targetMilliseconds": 200,
                ],
            ],
            shortcutNames: [],
            importedModuleIDs: []
        )
        let plan = LegacyUpgradeScanner.plan(
            manifest: manifest,
            contract: contract,
            enabledSwitchboardIDs: [],
            snapshot: snapshot,
            homeDirectory: home
        )
        let kinetics = try #require(plan.modules.first { $0.module.id == "desktop.kinetics" })
        #expect(kinetics.legacyEnabled)
        #expect(kinetics.recommendedSelected)
        #expect(kinetics.components.first { $0.component.id == "kinetics-app" }?.detection == .running)
        #expect(kinetics.legacySettingsSummary.contains("animation behavior"))
    }

    @Test
    func unresolvedSchedulerIsVisibleAndNeverMigratable() throws {
        let (manifest, contract) = try resources()
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let label = "com.ivogundlach.memory.graphify.semantic"
        let snapshot = LegacyUpgradeScanSnapshot(
            existingPaths: [home.appending(path: "Library/LaunchAgents/\(label).plist").path],
            runningAppPaths: [],
            loadedLaunchAgentLabels: [label],
            cronText: "",
            defaultsDomains: [:],
            shortcutNames: [],
            importedModuleIDs: []
        )
        let plan = LegacyUpgradeScanner.plan(
            manifest: manifest,
            contract: contract,
            enabledSwitchboardIDs: [],
            snapshot: snapshot,
            homeDirectory: home
        )
        let memory = try #require(plan.modules.first { $0.module.id == "systems.memory" })
        let component = try #require(memory.components.first { $0.component.id == "memory-graphify-semantic" })
        #expect(component.detection == .retained)
        #expect(!component.isMigratable)
        #expect(memory.hasRetainedEvidence)
    }

    @Test
    func importedCommandsDoNotCreateASecondMigration() throws {
        let (manifest, contract) = try resources()
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let snapshot = LegacyUpgradeScanSnapshot(
            existingPaths: [home.appending(path: ".local/bin/swift-smoke").path],
            runningAppPaths: [],
            loadedLaunchAgentLabels: [],
            cronText: "",
            defaultsDomains: [:],
            shortcutNames: [],
            importedModuleIDs: ["systems.advanced-commands"]
        )
        let plan = LegacyUpgradeScanner.plan(
            manifest: manifest,
            contract: contract,
            enabledSwitchboardIDs: ["systems.advanced-commands"],
            snapshot: snapshot,
            homeDirectory: home
        )
        let commands = try #require(plan.modules.first { $0.module.id == "systems.advanced-commands" })
        #expect(!commands.hasMigratableEvidence)
    }

    @Test
    func onlyMacBrightnessShortcutsBecomeSwitchboardEvidence() throws {
        let (manifest, contract) = try resources()
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let snapshot = LegacyUpgradeScanSnapshot(
            existingPaths: [],
            runningAppPaths: [],
            loadedLaunchAgentLabels: [],
            cronText: "",
            defaultsDomains: [:],
            shortcutNames: ["Set Mac Day Brightness", "Water Eject"],
            importedModuleIDs: []
        )
        let plan = LegacyUpgradeScanner.plan(
            manifest: manifest,
            contract: contract,
            enabledSwitchboardIDs: [],
            snapshot: snapshot,
            homeDirectory: home
        )
        let brightness = try #require(plan.modules.first { $0.module.id == "desktop.brightness" })
        #expect(brightness.components.first { $0.component.id == "mac-day-brightness-shortcut" }?.detection == .enabled)
        #expect(brightness.components.first { $0.component.id == "mac-night-brightness-shortcut" }?.detection == .notFound)
        #expect(brightness.recommendedSelected)
    }

    @Test
    func relocatedAppIsVisibleButNeverAuthorizedForMutation() throws {
        let (manifest, contract) = try resources()
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let snapshot = LegacyUpgradeScanSnapshot(
            existingPaths: [],
            runningAppPaths: [],
            loadedLaunchAgentLabels: [],
            cronText: "",
            defaultsDomains: [:],
            shortcutNames: [],
            importedModuleIDs: [],
            uncertainAppPaths: ["kinetics-app": ["/Users/test/Downloads/Kinetics.app"]]
        )
        let plan = LegacyUpgradeScanner.plan(
            manifest: manifest,
            contract: contract,
            enabledSwitchboardIDs: [],
            snapshot: snapshot,
            homeDirectory: home
        )
        let kinetics = try #require(plan.modules.first { $0.module.id == "desktop.kinetics" })
        let app = try #require(kinetics.components.first { $0.component.id == "kinetics-app" })
        #expect(app.detection == .unresolved)
        #expect(!app.isMigratable)
        #expect(app.isDetected)
    }

    private func resources() throws -> (ModuleManifest, UpgradeMigrationContract) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = root.appending(path: "Sources/Switchboard/Resources/ModuleManifest.json")
        let contractURL = root.appending(path: "Sources/Switchboard/Resources/UpgradeMigrationContract.json")
        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: manifestURL))
        let contract = try UpgradeMigrationContract.load(
            from: contractURL,
            moduleIDs: Set(manifest.modules.map(\.id))
        )
        return (manifest, contract)
    }
}
