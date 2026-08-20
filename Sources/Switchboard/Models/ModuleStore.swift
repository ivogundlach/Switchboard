import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class ModuleStore {
    private static let enabledKey = "switchboard.enabledModuleIDs"

    let manifest: ModuleManifest
    let warmCorners: WarmCornerSettings
    private let warmCornerRuntime: WarmCornerRuntime
    private let operationCoordinator = OperationCoordinator()
    @ObservationIgnored
    private lazy var warmCornersMigration: WarmCornersMigrationService = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "Switchboard", directoryHint: .isDirectory)
        return WarmCornersMigrationService(
            settings: warmCorners,
            coordinator: operationCoordinator,
            ledger: MigrationLedger(fileURL: applicationSupport.appending(path: "migration-ledger.json")),
            recoveryStore: RecoveryStore(rootURL: applicationSupport.appending(path: "Recovery", directoryHint: .isDirectory))
        )
    }()

    private(set) var enabledModuleIDs: Set<String>
    var selectedModuleID: String?
    var lastError: String?

    init() {
        do {
            let url = Bundle.main.url(forResource: "ModuleManifest", withExtension: "json")!
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(ModuleManifest.self, from: data)
        } catch {
            fatalError("Switchboard module manifest is invalid: \(error)")
        }

        enabledModuleIDs = Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
        warmCorners = WarmCornerSettings()
        warmCornerRuntime = WarmCornerRuntime(settings: warmCorners)

        let validIDs = Set(manifest.modules.map(\.id))
        enabledModuleIDs.formIntersection(validIDs)
        enabledModuleIDs = ModuleSelectionPolicy.sanitizedEnabledIDs(
            enabledModuleIDs,
            modules: manifest.modules
        )
        persistEnabledModules()

        selectedModuleID = manifest.modules.first?.id
    }

    func resumePersistedModules() async {
        guard enabledModuleIDs.contains("desktop.warm-corners"),
              let module = manifest.modules.first(where: { $0.id == "desktop.warm-corners" }) else {
            return
        }
        await enableWarmCorners(module)
    }

    var groups: [String] {
        Array(Set(manifest.modules.map(\.group))).sorted { lhs, rhs in
            let order = ["Desktop Controls", "Mail", "Files & Links", "Local Data", "Agent Systems"]
            return (order.firstIndex(of: lhs) ?? .max) < (order.firstIndex(of: rhs) ?? .max)
        }
    }

    func modules(in group: String) -> [ModuleDefinition] {
        manifest.modules.filter { $0.group == group }
    }

    func module(id: String?) -> ModuleDefinition? {
        guard let id else { return nil }
        return manifest.modules.first { $0.id == id }
    }

    func scheduledComponents(for module: ModuleDefinition) -> [ScheduledComponent] {
        manifest.scheduledComponents.filter { $0.owner == "switchboard:\(module.id)" }
    }

    func commands(for module: ModuleDefinition) -> [String] {
        var values = manifest.ownedCommandFamilies
            .filter { $0.owner == "switchboard:\(module.id)" }
            .flatMap(\.items)
        if module.id == "systems.memory" {
            values.append(contentsOf: manifest.memoryToolCandidates)
        }
        return values.sorted()
    }

    func services(for module: ModuleDefinition) -> [OwnedService] {
        manifest.macOSServices.filter { $0.owner == "switchboard:\(module.id)" }
    }

    func isEnabled(_ module: ModuleDefinition) -> Bool {
        enabledModuleIDs.contains(module.id)
    }

    func canEnable(_ module: ModuleDefinition) -> Bool {
        ModuleSelectionPolicy.canEnable(module)
    }

    func setEnabled(_ enabled: Bool, module: ModuleDefinition) {
        guard canEnable(module) else {
            lastError = "\(module.name) is listed, but its migration contract has not passed verification yet."
            return
        }

        if enabled {
            if module.id == "desktop.warm-corners" {
                Task { await enableWarmCorners(module) }
                return
            }
            enabledModuleIDs.insert(module.id)
        } else {
            enabledModuleIDs.remove(module.id)
        }
        persistEnabledModules()

        if module.id == "desktop.warm-corners" {
            enabled ? warmCornerRuntime.start() : warmCornerRuntime.stop()
        }
    }

    func health(for module: ModuleDefinition) -> ModuleHealth {
        guard canEnable(module) else {
            return .unavailable(module.availability.label)
        }
        if isEnabled(module) {
            if module.id == "desktop.warm-corners" {
                return warmCornerRuntime.isRunning
                    ? .ready(warmCorners.hasAnyCornerSet ? "Running" : "Running · no corners assigned")
                    : .unavailable("Enabled · watcher stopped")
            }
            return .ready("Enabled")
        }
        return .disabled("Off")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                lastError = "Start at Login could not be changed: \(error.localizedDescription)"
            }
        }
    }

    private func persistEnabledModules() {
        UserDefaults.standard.set(enabledModuleIDs.sorted(), forKey: Self.enabledKey)
    }

    private func enableWarmCorners(_ module: ModuleDefinition) async {
        do {
            _ = try await warmCornersMigration.importLegacyIfNeeded()
            enabledModuleIDs.insert(module.id)
            persistEnabledModules()
            warmCornerRuntime.start()
        } catch {
            enabledModuleIDs.remove(module.id)
            persistEnabledModules()
            warmCornerRuntime.stop()
            lastError = error.localizedDescription
        }
    }
}

enum ModuleSelectionPolicy {
    static func canEnable(_ module: ModuleDefinition) -> Bool {
        module.availability == .pilot
    }

    static func sanitizedEnabledIDs(
        _ requested: Set<String>,
        modules: [ModuleDefinition]
    ) -> Set<String> {
        let allowed = Set(modules.filter(canEnable).map(\.id))
        return requested.intersection(allowed)
    }
}
