import AppKit
import Darwin
import Foundation
import Observation
import ServiceManagement

enum UpgradeExecutionState: Equatable {
    case idle
    case confirmed
    case waitingForPermissions
    case running(String, String)
    case completed
    case completedWithIssues
    case failed(String)
}

enum UpgradeAttentionTarget: Equatable {
    case permissions
    case moduleResult(String)

    var scrollID: String {
        switch self {
        case .permissions: "upgrade-permissions"
        case .moduleResult(let moduleID): "upgrade-result-\(moduleID)"
        }
    }
}

struct UpgradeAttentionEvent: Equatable {
    let target: UpgradeAttentionTarget
    let sequence: Int
}

@MainActor
@Observable
final class ModuleStore {
    private static let enabledKey = "switchboard.enabledModuleIDs"
    private static let setupCompleteKey = "switchboard.setup.completed.v1"

    let manifest: ModuleManifest
    let upgradeContract: UpgradeMigrationContract
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
    @ObservationIgnored
    private let kineticsHandoffStore = KineticsUpgradeHandoffStore()
    @ObservationIgnored
    private let permissionOnboarding = PermissionOnboardingService()

    private(set) var enabledModuleIDs: Set<String>
    var selectedModuleID: String?
    var lastError: String?
    private(set) var upgradePlan: LegacyUpgradeReviewPlan
    private(set) var upgradeSelectedModuleIDs: Set<String> = []
    private(set) var upgradePermissionReviews: [UpgradePermissionReview] = []
    private(set) var upgradeState: UpgradeExecutionState = .idle
    private(set) var upgradeResults: [String: String] = [:]
    private(set) var upgradeAttention: UpgradeAttentionEvent?
    @ObservationIgnored
    private var upgradeHealthNonces: [String: String] = [:]
    @ObservationIgnored
    private var activeUpgradeLock: UpgradeExecutionLock?
    @ObservationIgnored
    private var upgradeAttentionSequence = 0

    var warmCornersRuntimeReady: Bool { warmCornerRuntime.isRunning }

    func stopWarmCornersForMigrationRollback() {
        warmCornerRuntime.stop()
    }

    func reinitializeWarmCornersForUserLaunch() {
        guard enabledModuleIDs.contains("desktop.warm-corners") else { return }
        if !warmCornerRuntime.restart() {
            lastError = "Warm Corners could not restart its pointer watcher. Check Switchboard's Accessibility permission."
        }
    }

    init() {
        do {
            let url = Bundle.main.url(forResource: "ModuleManifest", withExtension: "json")!
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(ModuleManifest.self, from: data)
            let contractURL = Bundle.main.url(forResource: "UpgradeMigrationContract", withExtension: "json")!
            upgradeContract = try UpgradeMigrationContract.load(
                from: contractURL,
                moduleIDs: Set(manifest.modules.map(\.id))
            )
        } catch {
            fatalError("Switchboard module manifest is invalid: \(error)")
        }

        enabledModuleIDs = Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
        upgradePlan = LegacyUpgradeReviewPlan(modules: [], createdAt: Date())
        warmCorners = WarmCornerSettings()
        warmCornerRuntime = WarmCornerRuntime(settings: warmCorners)
        scheduledModuleIDs = Self.loadScheduledModuleIDs()
        reconcilePendingUpgradeTransactions()

        let validIDs = Set(manifest.modules.map(\.id))
        enabledModuleIDs.formIntersection(validIDs)
        enabledModuleIDs = ModuleSelectionPolicy.sanitizedEnabledIDs(
            enabledModuleIDs,
            modules: manifest.modules
        )
        persistEnabledModules()
        resumePendingKineticsMigration()

        upgradePlan = LegacyUpgradeScanner.scan(
            manifest: manifest,
            contract: upgradeContract,
            enabledSwitchboardIDs: enabledModuleIDs
        )
        upgradeSelectedModuleIDs = Set(
            upgradePlan.modules.filter(\.recommendedSelected).map(\.module.id)
        )

        selectedModuleID = manifest.modules.first?.id
    }

    var hasActionableUpgrade: Bool {
        upgradePlan.shouldPresentOnUserLaunch || !UserDefaults.standard.bool(forKey: Self.setupCompleteKey)
    }

    func setUpgradeSelected(_ selected: Bool, moduleID: String) {
        if selected { upgradeSelectedModuleIDs.insert(moduleID) }
        else { upgradeSelectedModuleIDs.remove(moduleID) }
        refreshPermissionReviews()
    }

    func confirmUpgrade() {
        guard !upgradeSelectedModuleIDs.isEmpty else {
            if !upgradePlan.shouldPresentOnUserLaunch {
                UserDefaults.standard.set(true, forKey: Self.setupCompleteKey)
                upgradeState = .completed
                return
            }
            upgradeState = .failed("Choose at least one detected utility to upgrade.")
            return
        }
        upgradeState = .confirmed
        refreshPermissionReviews()
        continueConfirmedUpgradeIfReady()
    }

    func requestPermission(_ review: UpgradePermissionReview) {
        permissionOnboarding.request(review.permission)
        refreshPermissionReviews()
        continueConfirmedUpgradeIfReady()
    }

    func revealPermissionSubject(_ review: UpgradePermissionReview) {
        permissionOnboarding.revealSubject(review.permission)
    }

    func confirmAppManagement(_ review: UpgradePermissionReview) {
        permissionOnboarding.markAppManagementConfirmed(review.permission)
        refreshPermissionReviews()
        continueConfirmedUpgradeIfReady()
    }

    func checkPermissionsAgain() {
        refreshPermissionReviews()
        continueConfirmedUpgradeIfReady()
    }

    func refreshUpgradePlan() {
        upgradePlan = LegacyUpgradeScanner.scan(
            manifest: manifest,
            contract: upgradeContract,
            enabledSwitchboardIDs: enabledModuleIDs
        )
        refreshPermissionReviews()
    }

    func resumePersistedModules() async {
        for module in manifest.modules where enabledModuleIDs.contains(module.id) {
            switch module.id {
            case "desktop.warm-corners":
                _ = await enableWarmCorners(module)
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
        await resumeKineticsHandoffIfNeeded()
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
            Task { _ = await enableModule(module) }
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

    @discardableResult
    private func persistEnabledModules(presentsError: Bool = true) -> String? {
        UserDefaults.standard.set(enabledModuleIDs.sorted(), forKey: Self.enabledKey)
        do {
            try ModuleSelectionFile.save(enabledModuleIDs, to: applicationSupportURL)
            return nil
        } catch {
            let message = "Module selection could not be saved for the background agent: \(error.localizedDescription)"
            if presentsError { lastError = message }
            return message
        }
    }

    @discardableResult
    private func synchronizeAgentRegistration(presentsError: Bool = true) -> String? {
        do {
            try agentRegistration.synchronize(
                shouldRun: !enabledModuleIDs.isDisjoint(with: scheduledModuleIDs)
            )
            return nil
        } catch {
            let message = "The Switchboard background agent could not be updated: \(error.localizedDescription)"
            if presentsError { lastError = message }
            return message
        }
    }

    private static func loadScheduledModuleIDs() -> Set<String> {
        guard let url = Bundle.main.url(forResource: "RuntimeManifest", withExtension: "json"),
              let runtime = try? JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url)) else {
            return []
        }
        return Set(runtime.jobs.map(\.moduleID))
    }

    private func enableWarmCorners(
        _ module: ModuleDefinition,
        presentsError: Bool = true
    ) async -> String? {
        do {
            if WarmCornersLiveMigration.completedTransactionID == nil {
                _ = try await warmCornersMigration.importLegacyIfNeeded()
            }
            enabledModuleIDs.insert(module.id)
            if let error = persistEnabledModules(presentsError: false) {
                throw ModuleActivationError.failed(error)
            }
            warmCornerRuntime.start()
            return nil
        } catch {
            enabledModuleIDs.remove(module.id)
            _ = persistEnabledModules(presentsError: false)
            warmCornerRuntime.stop()
            let message = error.localizedDescription
            if presentsError { lastError = message }
            return message
        }
    }

    private func enableModule(
        _ module: ModuleDefinition,
        presentsError: Bool = true
    ) async -> String? {
        if module.id == "desktop.warm-corners" {
            return await enableWarmCorners(module, presentsError: presentsError)
        }
        if module.id == "desktop.kinetics" {
            return await enableKinetics(module, presentsError: presentsError)
        }

        let commandNames = commands(for: module)
        let serviceNames = services(for: module).map(\.name)
        let ownsScheduledJobs = scheduledModuleIDs.contains(module.id)
        let requiresCanonicalInstall = !commandNames.isEmpty || !serviceNames.isEmpty ||
            !module.legacyLabels.isEmpty || ownsScheduledJobs
        guard !requiresCanonicalInstall || CanonicalInstallGate.isCanonical() else {
            let message = "Install Switchboard in Applications before enabling \(module.name)."
            if presentsError { lastError = message }
            return message
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
            let safeLegacyLabels = migratableLegacyLabels(for: module)
            if !safeLegacyLabels.isEmpty {
                try await migrateLegacySchedulers(
                    moduleID: module.id,
                    labels: safeLegacyLabels
                )
            }

            enabledModuleIDs.insert(module.id)
            if let error = persistEnabledModules(presentsError: false) {
                throw ModuleActivationError.failed(error)
            }
            startLocalRuntime(for: module)
            if let error = synchronizeAgentRegistration(presentsError: false) {
                throw ModuleActivationError.failed(error)
            }
            return nil
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
            _ = persistEnabledModules(presentsError: false)
            stopLocalRuntime(for: module)
            _ = synchronizeAgentRegistration(presentsError: false)
            let message = "\(module.name) was not enabled: \(error.localizedDescription)"
            if presentsError { lastError = message }
            return message
        }
    }

    private func migratableLegacyLabels(for module: ModuleDefinition) -> [String] {
        upgradeContract.modules.first(where: { $0.moduleID == module.id })?.legacyComponents.compactMap {
            guard $0.disposition == .migrate,
                  $0.kind == .launchAgent || $0.kind == .cron else { return nil }
            return $0.label
        } ?? []
    }

    private func reconcilePendingUpgradeTransactions() {
        do {
            let lock = try UpgradeExecutionLock()
            defer { withExtendedLifetime(lock) {} }
            _ = try LegacyAppRetirement().reconcileInterruptedRetirements()
            for module in manifest.modules {
                let labels = migratableLegacyLabels(for: module)
                guard !labels.isEmpty else { continue }
                _ = try LegacySchedulerMigration(
                    moduleID: module.id,
                    legacyLabels: labels
                ).reconcileInterruptedMigration()
            }
            if let record = try kineticsHandoffStore.load() {
                switch record.phase {
                case .planned, .stopIntent, .legacyStopped, .replacementSelected, .replacementHealthy:
                    try restoreKineticsHandoff(record)
                    _ = try kineticsHandoffStore.transition(record, to: .rolledBack)
                case .legacyLoginRetirementIntent, .legacyLoginRetired, .committed, .rolledBack:
                    break
                }
            }
        } catch UpgradeExecutionLockError.unavailable {
            // Another process owns the transaction. It will finish or reconcile it.
        } catch {
            lastError = "An interrupted legacy migration needs attention: \(error.localizedDescription)"
        }
    }

    private func resumeKineticsHandoffIfNeeded() async {
        do {
            guard var record = try kineticsHandoffStore.load(),
                  record.phase == .legacyLoginRetirementIntent || record.phase == .legacyLoginRetired else {
                return
            }
            upgradeHealthNonces[KineticsCompanionController.moduleID] = record.healthNonce
            guard let module = module(id: KineticsCompanionController.moduleID),
                  await waitForReplacementHealth(module) else {
                switch KineticsUpgradeRecoveryAction.decide(
                    phase: record.phase,
                    legacyLoginStatus: kineticsLegacyMigration.legacyStatus
                ) {
                case .rollbackToLegacy:
                    try restoreKineticsHandoff(record)
                    _ = try kineticsHandoffStore.transition(record, to: .rolledBack)
                    lastError = "Kinetics replacement health did not recover; the old app was restarted for this session."
                case .keepReplacementPending:
                    lastError = "Kinetics still needs its replacement permission or health check. The verified replacement remains selected because the old login item may already be retired."
                case .none:
                    break
                }
                return
            }
            if record.phase == .legacyLoginRetirementIntent {
                try kineticsLegacyMigration.retireLegacyLoginAfterHealthyReplacement(
                    currentSelection: enabledModuleIDs,
                    validateCompanion: { [bundleURL = Bundle.main.bundleURL] in
                        _ = try KineticsCompanionController.validate(bundleURL: bundleURL)
                    }
                )
                record = try kineticsHandoffStore.transition(record, to: .legacyLoginRetired)
            }
            if let component = upgradeContract.modules
                .first(where: { $0.moduleID == KineticsCompanionController.moduleID })?
                .legacyComponents.first(where: { $0.id == "kinetics-app" }),
               FileManager.default.fileExists(atPath: component.canonicalPath ?? "") {
                _ = try LegacyAppRetirement().retire(component)
            }
            _ = try kineticsHandoffStore.transition(record, to: .committed)
            markUpgradeImported(KineticsCompanionController.moduleID)
        } catch {
            lastError = "Kinetics migration recovery needs attention: \(error.localizedDescription)"
        }
    }

    private func restoreKineticsHandoff(_ record: KineticsUpgradeHandoffRecord) throws {
        try persistKineticsSelection(Set(record.priorSelection))
        synchronizeAgentRegistration()
        guard record.legacyWasRunning,
              FileManager.default.fileExists(atPath: record.legacyAppPath) else { return }
        let component = UpgradeLegacyComponent(
            id: "kinetics-app",
            displayName: "Kinetics app",
            kind: .appBundle,
            disposition: .migrate,
            canonicalPath: record.legacyAppPath,
            bundleID: KineticsCompanionController.bundleIdentifier,
            executableName: record.legacyExecutableName
        )
        if !legacyAppIsRunning(component) {
            try restoreLegacyApps([.init(component: component, wasRunning: true)])
        }
    }

    private func refreshPermissionReviews() {
        upgradePermissionReviews = permissionOnboarding.reviews(
            for: upgradeSelectedModuleIDs,
            plan: upgradePlan
        )
        if case .confirmed = upgradeState, upgradePermissionReviews.contains(where: { $0.readiness.isBlocking }) {
            upgradeState = .waitingForPermissions
        }
    }

    private func continueConfirmedUpgradeIfReady() {
        guard upgradeState == .confirmed || upgradeState == .waitingForPermissions else { return }
        guard !upgradePermissionReviews.contains(where: { $0.readiness.isBlocking }) else {
            upgradeState = .waitingForPermissions
            requestUpgradeAttention(.permissions)
            return
        }
        Task { await performConfirmedUpgrade() }
    }

    private func enableKinetics(
        _ module: ModuleDefinition,
        presentsError: Bool = true
    ) async -> String? {
        guard CanonicalInstallGate.isCanonical() else {
            let message = "Install Switchboard in Applications before enabling \(module.name)."
            if presentsError { lastError = message }
            return message
        }
        kinetics.refresh(bundleURL: Bundle.main.bundleURL)
        guard kinetics.isReady else {
            let message = "\(module.name) was not enabled: \(kinetics.lastFailure ?? "the nested companion is unavailable")"
            if presentsError { lastError = message }
            return message
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
            if let error = synchronizeAgentRegistration(presentsError: false) {
                throw ModuleActivationError.failed(error)
            }
            return nil
        } catch {
            kinetics.stop()
            let message = "\(module.name) was not enabled: \(error.localizedDescription)"
            if presentsError { lastError = message }
            return message
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

    private func performConfirmedUpgrade() async {
        guard CanonicalInstallGate.isCanonical() else {
            upgradeState = .failed("Install Switchboard in Applications before upgrading legacy utilities.")
            return
        }
        let executionLock: UpgradeExecutionLock
        do {
            executionLock = try UpgradeExecutionLock()
        } catch {
            upgradeState = .failed(error.localizedDescription)
            return
        }
        _ = executionLock
        activeUpgradeLock = executionLock
        defer { activeUpgradeLock = nil }
        upgradeResults = [:]
        upgradeAttention = nil
        var encounteredIssue = false

        for review in upgradePlan.modules where upgradeSelectedModuleIDs.contains(review.module.id) {
            let migratable = review.components.filter(\.isMigratable)
            guard !migratable.isEmpty || !review.hasLegacyEvidence else { continue }
            upgradeState = .running(review.module.id, "Preparing \(review.module.name)")
            var stoppedApps: [UpgradeStoppedLegacyApp] = []
            var kineticsHandoff: KineticsUpgradeHandoffRecord?
            do {
                let healthNonce = try beginHealthAttempt(moduleID: review.module.id)
                if review.module.id == KineticsCompanionController.moduleID,
                   let component = migratable.first(where: { $0.component.id == "kinetics-app" })?.component,
                   let path = component.canonicalPath,
                   let executable = component.executableName {
                    kineticsHandoff = try kineticsHandoffStore.begin(
                        healthNonce: healthNonce,
                        legacyAppPath: path,
                        legacyExecutableName: executable,
                        legacyWasRunning: legacyAppIsRunning(component),
                        priorSelection: enabledModuleIDs
                    )
                    kineticsHandoff = try kineticsHandoffStore.transition(kineticsHandoff!, to: .stopIntent)
                }
                stoppedApps = try await quiesceLegacyApps(migratable)
                if let record = kineticsHandoff {
                    kineticsHandoff = try kineticsHandoffStore.transition(record, to: .legacyStopped)
                }
                if review.module.id == KineticsCompanionController.moduleID {
                    try await enableKineticsForUpgrade(review.module)
                    kineticsHandoff = try kineticsHandoff.map {
                        try kineticsHandoffStore.transition($0, to: .replacementSelected)
                    }
                } else if !isEnabled(review.module) {
                    if let activationError = await enableModule(
                        review.module,
                        presentsError: false
                    ) {
                        throw UpgradeExecutionError.activationFailed(activationError)
                    }
                    guard isEnabled(review.module) else {
                        throw UpgradeExecutionError.activationFailed("the replacement did not enable")
                    }
                } else {
                    // Existing Switchboard state does not suppress a legacy handoff.
                    let labels = migratableLegacyLabels(for: review.module)
                    if !labels.isEmpty {
                        try await migrateLegacySchedulers(
                            moduleID: review.module.id,
                            labels: labels
                        )
                    }
                }

                upgradeState = .running(review.module.id, "Verifying \(review.module.name)")
                guard await waitForReplacementHealth(review.module) else {
                    if review.module.id != KineticsCompanionController.moduleID {
                        await restoreLegacySchedulers(
                            moduleID: review.module.id,
                            labels: migratableLegacyLabels(for: review.module)
                        )
                        disableModule(review.module)
                        try restoreLegacyApps(stoppedApps)
                        stoppedApps = []
                    }
                    throw UpgradeExecutionError.healthFailed("the replacement did not prove its required behavior")
                }

                if let record = kineticsHandoff {
                    kineticsHandoff = try kineticsHandoffStore.transition(record, to: .replacementHealthy)
                }

                if review.module.id == KineticsCompanionController.moduleID {
                    if let record = kineticsHandoff {
                        kineticsHandoff = try kineticsHandoffStore.transition(record, to: .legacyLoginRetirementIntent)
                    }
                    try kineticsLegacyMigration.retireLegacyLoginAfterHealthyReplacement(
                        currentSelection: enabledModuleIDs,
                        validateCompanion: { [bundleURL = Bundle.main.bundleURL] in
                            _ = try KineticsCompanionController.validate(bundleURL: bundleURL)
                        }
                    )
                    if let record = kineticsHandoff {
                        kineticsHandoff = try kineticsHandoffStore.transition(record, to: .legacyLoginRetired)
                    }
                }

                var retirementPending = false
                let retirement = LegacyAppRetirement()
                for evidence in migratable where evidence.component.kind == .appBundle && evidence.isDetected {
                    do {
                        _ = try retirement.retire(evidence.component)
                    } catch LegacyAppRetirementError.sourceMissing {
                        continue
                    } catch {
                        retirementPending = true
                        encounteredIssue = true
                        upgradeResults[review.module.id] = "Replacement active; old app is disabled but still installed: \(error.localizedDescription)"
                        requestUpgradeAttention(.moduleResult(review.module.id))
                    }
                }
                markUpgradeImported(review.module.id)
                if !retirementPending {
                    upgradeResults[review.module.id] = "Migrated, verified, and retired recoverably"
                    if let record = kineticsHandoff {
                        kineticsHandoff = try kineticsHandoffStore.transition(record, to: .committed)
                    }
                }
            } catch {
                if review.module.id == KineticsCompanionController.moduleID {
                    if let record = kineticsHandoff {
                        switch KineticsUpgradeRecoveryAction.decide(
                            phase: record.phase,
                            legacyLoginStatus: kineticsLegacyMigration.legacyStatus
                        ) {
                        case .rollbackToLegacy:
                            disableModule(review.module)
                            try? restoreLegacyApps(stoppedApps)
                            _ = try? kineticsHandoffStore.transition(record, to: .rolledBack)
                        case .keepReplacementPending:
                            // The legacy login item may already be gone. Keep the healthy
                            // replacement selected and the journal pending for startup recovery.
                            break
                        case .none:
                            break
                        }
                    } else {
                        disableModule(review.module)
                        try? restoreLegacyApps(stoppedApps)
                    }
                }
                encounteredIssue = true
                upgradeResults[review.module.id] = error.localizedDescription
                requestUpgradeAttention(.moduleResult(review.module.id))
            }
        }

        refreshUpgradePlan()
        UserDefaults.standard.set(true, forKey: Self.setupCompleteKey)
        upgradeState = encounteredIssue ? .completedWithIssues : .completed
    }

    private func requestUpgradeAttention(_ target: UpgradeAttentionTarget) {
        upgradeAttentionSequence += 1
        upgradeAttention = UpgradeAttentionEvent(
            target: target,
            sequence: upgradeAttentionSequence
        )
    }

    private func migrateLegacySchedulers(moduleID: String, labels: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try LegacySchedulerMigration(
                moduleID: moduleID,
                legacyLabels: labels
            ).migrate()
        }.value
    }

    private func restoreLegacySchedulers(moduleID: String, labels: [String]) async {
        _ = try? await Task.detached(priority: .userInitiated) {
            try LegacySchedulerMigration(
                moduleID: moduleID,
                legacyLabels: labels
            ).restoreLastMigration()
        }.value
    }

    private func enableKineticsForUpgrade(_ module: ModuleDefinition) async throws {
        kinetics.refresh(bundleURL: Bundle.main.bundleURL)
        guard kinetics.isReady else {
            throw UpgradeExecutionError.activationFailed(kinetics.lastFailure ?? "the nested Kinetics companion is unavailable")
        }
        if !enabledModuleIDs.contains(module.id) {
            var selection = enabledModuleIDs
            selection.insert(module.id)
            try persistKineticsSelection(selection)
        }
        if let error = synchronizeAgentRegistration(presentsError: false) {
            throw UpgradeExecutionError.activationFailed(error)
        }
    }

    private func quiesceLegacyApps(
        _ evidence: [LegacyUpgradeComponentEvidence]
    ) async throws -> [UpgradeStoppedLegacyApp] {
        var stopped: [UpgradeStoppedLegacyApp] = []
        let retirement = LegacyAppRetirement()
        for item in evidence where item.component.kind == .appBundle && item.isDetected {
            guard let path = item.component.canonicalPath,
                  let bundleID = item.component.bundleID,
                  let executable = item.component.executableName else { continue }
            let appURL = URL(fileURLWithPath: path, isDirectory: true)
            _ = try retirement.validate(appURL, bundleID: bundleID, executableName: executable)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.bundleURL?.standardizedFileURL == appURL.standardizedFileURL {
                let pid = app.processIdentifier
                guard processExecutablePath(pid) == appURL.appending(path: "Contents/MacOS/\(executable)").path,
                      app.terminate() else {
                    throw UpgradeExecutionError.quiescenceFailed("\(item.component.displayName) could not stop safely")
                }
                let deadline = Date().addingTimeInterval(6)
                while !app.isTerminated, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard app.isTerminated else {
                    throw UpgradeExecutionError.quiescenceFailed("\(item.component.displayName) did not stop")
                }
                stopped.append(.init(component: item.component, wasRunning: true))
            }
        }
        return stopped
    }

    private func restoreLegacyApps(_ stopped: [UpgradeStoppedLegacyApp]) throws {
        for item in stopped where item.wasRunning {
            guard let path = item.component.canonicalPath,
                  let executable = item.component.executableName else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
                .appending(path: "Contents/MacOS/\(executable)")
            process.arguments = ["--login"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    }

    private func waitForReplacementHealth(_ module: ModuleDefinition) async -> Bool {
        let deadline = Date().addingTimeInterval(50)
        var consecutiveReadyChecks = 0
        repeat {
            if replacementHealthReady(module) {
                consecutiveReadyChecks += 1
                if consecutiveReadyChecks >= 5 { return true }
            } else {
                consecutiveReadyChecks = 0
            }
            try? await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        return false
    }

    private func replacementHealthReady(_ module: ModuleDefinition) -> Bool {
        let bundle = Bundle.main.bundleURL
        guard let nonce = upgradeHealthNonces[module.id] ?? healthNonce(moduleID: module.id) else {
            return false
        }
        switch module.id {
        case "desktop.kinetics":
            let executable = bundle.appending(path: "Contents/Resources/Companions/Kinetics.app/Contents/MacOS/Kinetics")
            return ReplacementHealthService.helperCapability(
                named: "Kinetics",
                expectedBundleID: "com.ivogundlach.Kinetics",
                expectedExecutableURL: executable,
                expectedNonce: nonce
            ).ready && ReplacementHealthService.continuousAgentJob(
                label: "com.ivogundlach.Kinetics",
                expectedExecutableURL: executable,
                expectedNonce: nonce
            ).ready
        case "desktop.quit-on-close":
            let executable = bundle.appending(path: "Contents/Resources/Helpers/quit-on-close")
            return ReplacementHealthService.helperCapability(
                named: "QuitOnClose",
                expectedBundleID: "com.ivogundlach.quit-on-close",
                expectedExecutableURL: executable,
                expectedNonce: nonce
            ).ready
        case "desktop.smart-wake":
            return ReplacementHealthService.continuousAgentJob(
                label: "com.user.smartwake",
                expectedExecutableURL: bundle.appending(path: "Contents/Resources/Modules/desktop.smart-wake/bin/smart-wake.sh"),
                expectedNonce: nonce
            ).ready && smartWakeStatusIsCurrent()
        case "files.copy-path":
            return copyPath.isEnabled(bundleURL: bundle)
        case "mail.assistant":
            let readiness = permissionOnboarding.readiness(
                upgradeContract.modules.first(where: { $0.moduleID == module.id })!.permissions.first(where: {
                    $0.mechanism == .fullDiskAccessHelper
                })!,
                bundleURL: bundle
            )
            if case .ready = readiness { return true }
            return false
        default:
            if case .ready = health(for: module) { return true }
            return isEnabled(module)
        }
    }

    private func markUpgradeImported(_ moduleID: String) {
        UserDefaults.standard.set(true, forKey: "switchboard.upgrade.imported.\(moduleID).v1")
    }

    private func beginHealthAttempt(moduleID: String) throws -> String {
        guard LegacySchedulerMigration.isSafeComponent(moduleID) else {
            throw UpgradeExecutionError.activationFailed("the module identity is unsafe")
        }
        let nonce = UUID().uuidString
        let directory = applicationSupportURL.appending(path: "Upgrade", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appending(path: "health-nonce-\(moduleID).txt")
        try Data((nonce + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        upgradeHealthNonces[moduleID] = nonce
        return nonce
    }

    private func healthNonce(moduleID: String) -> String? {
        let url = applicationSupportURL.appending(path: "Upgrade/health-nonce-\(moduleID).txt")
        guard let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private func smartWakeStatusIsCurrent(now: Date = Date()) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/smart-wake/state/status.env")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= 30,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("NOW=") && text.contains("KEEP_AWAKE=")
            && text.contains("REASON=") && text.contains("MODE=")
    }

    private func legacyAppIsRunning(_ component: UpgradeLegacyComponent) -> Bool {
        guard let bundleID = component.bundleID, let path = component.canonicalPath else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }

    private func processExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return base.withMemoryRebound(to: UInt8.self, capacity: pointer.count) {
                String(decodingCString: $0, as: UTF8.self)
            }
        }
    }
}

private enum ModuleActivationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

private struct UpgradeStoppedLegacyApp {
    let component: UpgradeLegacyComponent
    let wasRunning: Bool
}

private enum UpgradeExecutionError: LocalizedError {
    case activationFailed(String)
    case quiescenceFailed(String)
    case healthFailed(String)

    var errorDescription: String? {
        switch self {
        case .activationFailed(let detail): "Replacement activation failed: \(detail)"
        case .quiescenceFailed(let detail): "Legacy handoff stopped safely: \(detail)"
        case .healthFailed(let detail): "Replacement verification failed: \(detail)"
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
