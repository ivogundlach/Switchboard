import AppKit
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
    private let audioGuard = AudioDisconnectGuardController()
    private let kinetics = KineticsCompanionController()
    let brightness = BrightnessController()
    private let copyPath = CopyPathController()
    let updates = UpdateCoordinator()
    private let agentRegistration = AgentRegistration()
    private let commandActivation = BundledCommandActivation()
    private let serviceActivation = BundledServiceActivation()
    private let scheduledModuleIDs: Set<String>
    private let operationCoordinator = OperationCoordinator()
    private let applicationSupportURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appending(path: "Switchboard", directoryHint: .isDirectory)
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
    @ObservationIgnored
    private lazy var kineticsLegacyMigration = KineticsLegacyLoginMigration()

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
        scheduledModuleIDs = Self.loadScheduledModuleIDs()

        let validIDs = Set(manifest.modules.map(\.id))
        enabledModuleIDs.formIntersection(validIDs)
        enabledModuleIDs = ModuleSelectionPolicy.sanitizedEnabledIDs(
            enabledModuleIDs,
            modules: manifest.modules
        )
        persistEnabledModules()
        resumePendingKineticsMigration()

        selectedModuleID = manifest.modules.first?.id
    }

    func resumePersistedModules() async {
        for module in manifest.modules where enabledModuleIDs.contains(module.id) {
            switch module.id {
            case "desktop.warm-corners":
                await enableWarmCorners(module)
            case "desktop.audio-guard":
                audioGuard.start()
            case "desktop.brightness":
                brightness.start()
            case "desktop.kinetics":
                kinetics.refresh(bundleURL: Bundle.main.bundleURL)
            case "files.copy-path":
                do {
                    try copyPath.enable(bundleURL: Bundle.main.bundleURL)
                } catch {
                    lastError = "Copy Path could not be enabled: \(error.localizedDescription)"
                }
            default:
                break
            }
        }
        synchronizeAgentRegistration()
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
            Task { await enableModule(module) }
        } else {
            disableModule(module)
        }
    }

    func health(for module: ModuleDefinition) -> ModuleHealth {
        guard canEnable(module) else {
            return .unavailable(module.availability.label)
        }
        if isEnabled(module) {
            switch module.id {
            case "desktop.warm-corners":
                return warmCornerRuntime.isRunning
                    ? .ready(warmCorners.hasAnyCornerSet ? "Running" : "Running · no corners assigned")
                    : .unavailable("Enabled · watcher stopped")
            case "desktop.audio-guard":
                return audioGuard.isRunning ? .ready("Watching audio output") : .unavailable("Enabled · watcher stopped")
            case "desktop.brightness":
                return brightness.isRunning ? .ready("Ready") : .unavailable("Enabled · controller stopped")
            case "desktop.kinetics":
                return kinetics.isReady
                    ? .ready("Ready · Switchboard agent owns background runtime")
                    : .unavailable("Enabled · companion unavailable")
            default:
                return .ready("Enabled")
            }
        }
        return .disabled("Off")
    }

    func checkForUpdates() {
        Task { await updates.check() }
    }

    func installAvailableUpdate() {
        Task {
            if await updates.installAvailableUpdate() {
                try? await Task.sleep(for: .milliseconds(250))
                NSApp.terminate(nil)
            }
        }
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
        do {
            try ModuleSelectionFile.save(enabledModuleIDs, to: applicationSupportURL)
        } catch {
            lastError = "Module selection could not be saved for the background agent: \(error.localizedDescription)"
        }
    }

    private func synchronizeAgentRegistration() {
        do {
            try agentRegistration.synchronize(
                shouldRun: !enabledModuleIDs.isDisjoint(with: scheduledModuleIDs)
            )
        } catch {
            lastError = "The Switchboard background agent could not be updated: \(error.localizedDescription)"
        }
    }

    private static func loadScheduledModuleIDs() -> Set<String> {
        guard let url = Bundle.main.url(forResource: "RuntimeManifest", withExtension: "json"),
              let runtime = try? JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url)) else {
            return []
        }
        return Set(runtime.jobs.map(\.moduleID))
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

    private func enableModule(_ module: ModuleDefinition) async {
        if module.id == "desktop.warm-corners" {
            await enableWarmCorners(module)
            return
        }
        if module.id == "desktop.kinetics" {
            await enableKinetics(module)
            return
        }

        let commandNames = commands(for: module)
        let serviceNames = services(for: module).map(\.name)
        let ownsScheduledJobs = scheduledModuleIDs.contains(module.id)
        let requiresCanonicalInstall = !commandNames.isEmpty || !serviceNames.isEmpty ||
            !module.legacyLabels.isEmpty || ownsScheduledJobs
        guard !requiresCanonicalInstall || CanonicalInstallGate.isCanonical() else {
            lastError = "Install Switchboard in Applications before enabling \(module.name)."
            return
        }

        var commandsActivated = false
        var servicesActivated = false
        var copyPathActivated = false
        do {
            if !commandNames.isEmpty {
                try commandActivation.enable(
                    bundleURL: Bundle.main.bundleURL,
                    moduleID: module.id,
                    commandNames: commandNames
                )
                commandsActivated = true
            }
            if !serviceNames.isEmpty {
                try serviceActivation.enable(
                    bundleURL: Bundle.main.bundleURL,
                    serviceNames: serviceNames
                )
                servicesActivated = true
            }
            if module.id == "files.copy-path" {
                try copyPath.enable(bundleURL: Bundle.main.bundleURL)
                copyPathActivated = true
            }
            if ownsScheduledJobs {
                // Registration may start the shared agent, but this module is
                // deliberately absent from ModuleSelectionFile until after its
                // legacy scheduler has been quiesced below. The agent therefore
                // cannot run old and replacement jobs at the same time.
                try agentRegistration.synchronize(shouldRun: true)
            }
            if !module.legacyLabels.isEmpty {
                _ = try LegacySchedulerMigration(
                    moduleID: module.id,
                    legacyLabels: module.legacyLabels
                ).migrate()
            }

            enabledModuleIDs.insert(module.id)
            persistEnabledModules()
            startLocalRuntime(for: module)
            synchronizeAgentRegistration()
        } catch {
            if servicesActivated {
                try? serviceActivation.disable(
                    bundleURL: Bundle.main.bundleURL,
                    serviceNames: serviceNames
                )
            }
            if copyPathActivated {
                try? copyPath.disable(bundleURL: Bundle.main.bundleURL)
            }
            if commandsActivated {
                try? commandActivation.disable(
                    bundleURL: Bundle.main.bundleURL,
                    moduleID: module.id,
                    commandNames: commandNames
                )
            }
            enabledModuleIDs.remove(module.id)
            persistEnabledModules()
            stopLocalRuntime(for: module)
            lastError = "\(module.name) was not enabled: \(error.localizedDescription)"
        }
    }

    private func enableKinetics(_ module: ModuleDefinition) async {
        guard CanonicalInstallGate.isCanonical() else {
            lastError = "Install Switchboard in Applications before enabling \(module.name)."
            return
        }
        kinetics.refresh(bundleURL: Bundle.main.bundleURL)
        guard kinetics.isReady else {
            lastError = "\(module.name) was not enabled: \(kinetics.lastFailure ?? "the nested companion is unavailable")"
            return
        }
        do {
            try kineticsLegacyMigration.enable(
                currentSelection: enabledModuleIDs,
                registerSharedAgent: { [agentRegistration] in
                    try agentRegistration.synchronize(shouldRun: true)
                },
                validateCompanion: { [bundleURL = Bundle.main.bundleURL] in
                    do { _ = try KineticsCompanionController.validate(bundleURL: bundleURL) }
                    catch { throw KineticsLegacyLoginMigrationError.companionUnavailable(error.localizedDescription) }
                },
                persistSelection: { [weak self] selection in
                    try self?.persistKineticsSelection(selection)
                }
            )
            synchronizeAgentRegistration()
        } catch {
            kinetics.stop()
            lastError = "\(module.name) was not enabled: \(error.localizedDescription)"
        }
    }

    private func resumePendingKineticsMigration() {
        guard CanonicalInstallGate.isCanonical() else { return }
        do {
            try kineticsLegacyMigration.resume(
                currentSelection: enabledModuleIDs,
                registerSharedAgent: { [agentRegistration] in
                    try agentRegistration.synchronize(shouldRun: true)
                },
                validateCompanion: { [bundleURL = Bundle.main.bundleURL] in
                    do { _ = try KineticsCompanionController.validate(bundleURL: bundleURL) }
                    catch { throw KineticsLegacyLoginMigrationError.companionUnavailable(error.localizedDescription) }
                },
                persistSelection: { [weak self] selection in
                    try self?.persistKineticsSelection(selection)
                }
            )
        } catch {
            enabledModuleIDs.remove(KineticsLegacyLoginMigration.moduleID)
            persistEnabledModules()
            lastError = "Kinetics migration could not resume safely: \(error.localizedDescription)"
        }
    }

    private func persistKineticsSelection(_ selection: Set<String>) throws {
        try ModuleSelectionFile.save(selection, to: applicationSupportURL)
        enabledModuleIDs = selection
        UserDefaults.standard.set(selection.sorted(), forKey: Self.enabledKey)
    }

    private func disableModule(_ module: ModuleDefinition) {
        let commandNames = commands(for: module)
        let serviceNames = services(for: module).map(\.name)
        do {
            if module.id == "files.copy-path" {
                try copyPath.disable(bundleURL: Bundle.main.bundleURL)
            }
            if !serviceNames.isEmpty, CanonicalInstallGate.isCanonical() {
                try serviceActivation.disable(
                    bundleURL: Bundle.main.bundleURL,
                    serviceNames: serviceNames
                )
            }
            if !commandNames.isEmpty, CanonicalInstallGate.isCanonical() {
                try commandActivation.disable(
                    bundleURL: Bundle.main.bundleURL,
                    moduleID: module.id,
                    commandNames: commandNames
                )
            }
            enabledModuleIDs.remove(module.id)
            persistEnabledModules()
            stopLocalRuntime(for: module)
            synchronizeAgentRegistration()
        } catch {
            lastError = "\(module.name) could not be disabled safely: \(error.localizedDescription)"
        }
    }

    private func startLocalRuntime(for module: ModuleDefinition) {
        switch module.id {
        case "desktop.audio-guard": audioGuard.start()
        case "desktop.brightness": brightness.start()
        case "desktop.kinetics": kinetics.refresh(bundleURL: Bundle.main.bundleURL)
        default: break
        }
    }

    private func stopLocalRuntime(for module: ModuleDefinition) {
        switch module.id {
        case "desktop.warm-corners": warmCornerRuntime.stop()
        case "desktop.audio-guard": audioGuard.stop()
        case "desktop.brightness": brightness.stop()
        case "desktop.kinetics": kinetics.stop()
        default: break
        }
    }
}

enum ModuleSelectionPolicy {
    static func canEnable(_ module: ModuleDefinition) -> Bool {
        module.availability == .pilot || module.availability == .ready
    }

    static func sanitizedEnabledIDs(
        _ requested: Set<String>,
        modules: [ModuleDefinition]
    ) -> Set<String> {
        let allowed = Set(modules.filter(canEnable).map(\.id))
        return requested.intersection(allowed)
    }
}
