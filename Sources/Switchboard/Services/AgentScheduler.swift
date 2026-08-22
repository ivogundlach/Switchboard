import Foundation

struct RuntimeManifest: Decodable {
    let schemaVersion: Int
    let jobs: [RuntimeJob]
}

struct RuntimeJob: Decodable, Identifiable, Equatable {
    let label: String
    let moduleID: String
    let executable: String
    let arguments: [String]
    let schedule: RuntimeSchedule
    var id: String { label }
}

struct RuntimeSchedule: Decodable, Equatable {
    enum Kind: String, Decodable { case daily, dailyTimes, hourlyWindow, interval, weekly, continuous }
    let kind: Kind
    let hour: Int?
    let minute: Int?
    let weekday: Int?
    let seconds: Int?
    let runAtLoad: Bool?
    let times: [String]?
    let startHour: Int?
    let endHour: Int?
    var weeklyAlso: WeeklyTime? = nil
}

struct WeeklyTime: Decodable, Equatable {
    let weekday: Int
    let hour: Int
    let minute: Int
}

struct AgentJobState: Codable, Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastFailure: String?
    var runningPID: Int32?
    var runningExecutablePath: String?
    var heartbeat: Date?
    var healthNonce: String?
    var processStartedAt: Date?
}

struct AgentStateFile: Codable, Equatable {
    var jobs: [String: AgentJobState] = [:]
}

enum RuntimeManifestValidator {
    static func validate(_ manifest: RuntimeManifest, moduleIDs: Set<String>) throws {
        guard manifest.schemaVersion == 1,
              Set(manifest.jobs.map(\.label)).count == manifest.jobs.count else {
            throw AgentError.invalidRuntimeManifest
        }
        for job in manifest.jobs {
            guard moduleIDs.contains(job.moduleID),
                  !job.executable.hasPrefix("/"),
                  !job.executable.split(separator: "/").contains(".."),
                  !job.label.isEmpty else {
                throw AgentError.invalidRuntimeManifest
            }
            try validate(job.schedule)
        }
    }

    private static func validate(_ schedule: RuntimeSchedule) throws {
        func validHour(_ value: Int?) -> Bool { value.map { (0...23).contains($0) } ?? false }
        func validMinute(_ value: Int?) -> Bool { value.map { (0...59).contains($0) } ?? false }
        let valid: Bool
        switch schedule.kind {
        case .daily:
            valid = validHour(schedule.hour) && validMinute(schedule.minute)
        case .dailyTimes:
            valid = !(schedule.times ?? []).isEmpty && (schedule.times ?? []).allSatisfy(TimeOfDay.isValid)
        case .hourlyWindow:
            valid = validMinute(schedule.minute) && validHour(schedule.startHour)
                && validHour(schedule.endHour) && schedule.startHour! <= schedule.endHour!
        case .interval:
            valid = (schedule.seconds ?? 0) >= 60
        case .weekly:
            valid = (1...7).contains(schedule.weekday ?? 0) && validHour(schedule.hour) && validMinute(schedule.minute)
        case .continuous:
            valid = true
        }
        let additionalWeeklyValid = schedule.weeklyAlso.map {
            (1...7).contains($0.weekday) && (0...23).contains($0.hour) && (0...59).contains($0.minute)
        } ?? true
        guard valid, additionalWeeklyValid else { throw AgentError.invalidRuntimeManifest }
    }
}

struct TimeOfDay: Equatable {
    let hour: Int
    let minute: Int

    init?(_ value: String) {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    static func isValid(_ value: String) -> Bool { TimeOfDay(value) != nil }
}

enum RuntimeDuePolicy {
    static func isDue(
        _ schedule: RuntimeSchedule,
        now: Date,
        lastAttempt: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let weeklyAlsoDue = schedule.weeklyAlso.map {
            components.weekday == $0.weekday && components.hour == $0.hour && components.minute == $0.minute
                && lastAttempt.map { !calendar.isDate($0, equalTo: now, toGranularity: .minute) } != false
        } ?? false
        if weeklyAlsoDue { return true }
        if schedule.kind == .continuous { return true }
        if schedule.kind == .interval {
            guard let lastAttempt else { return schedule.runAtLoad == true }
            return now.timeIntervalSince(lastAttempt) >= Double(schedule.seconds ?? .max)
        }
        guard let hour = components.hour, let minute = components.minute else { return false }
        let matches: Bool
        switch schedule.kind {
        case .daily:
            matches = hour == schedule.hour && minute == schedule.minute
        case .dailyTimes:
            matches = (schedule.times ?? []).compactMap(TimeOfDay.init).contains(TimeOfDay("\(hour):\(minute)"))
        case .hourlyWindow:
            matches = minute == schedule.minute && hour >= schedule.startHour! && hour <= schedule.endHour!
        case .weekly:
            matches = components.weekday == schedule.weekday && hour == schedule.hour && minute == schedule.minute
        case .continuous, .interval:
            matches = false
        }
        guard matches else { return false }
        guard let lastAttempt else { return true }
        return !calendar.isDate(lastAttempt, equalTo: now, toGranularity: .minute)
    }
}

final class SwitchboardAgent {
    private struct ActiveProcess {
        let process: Process
        let logHandle: FileHandle
        let continuous: Bool
        let executablePath: String
    }

    private let bundleURL: URL
    private let applicationSupportURL: URL
    private let fileManager: FileManager
    private var activeProcesses: [String: ActiveProcess] = [:]

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        applicationSupportURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Switchboard", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.bundleURL = bundleURL
        self.applicationSupportURL = applicationSupportURL
        self.fileManager = fileManager
    }

    func run() throws -> Never {
        let runtime = try loadRuntimeManifest()
        let modules = try loadModuleManifest()
        try RuntimeManifestValidator.validate(runtime, moduleIDs: Set(modules.modules.map(\.id)))
        while true {
            autoreleasepool { try? tick(runtime: runtime) }
            RunLoop.current.run(until: Date().addingTimeInterval(30))
        }
    }

    private func tick(runtime: RuntimeManifest) throws {
        let enabled = try ModuleSelectionFile.load(from: applicationSupportURL)
        var state = try loadState()
        reapCompletedProcesses(state: &state)
        for (label, active) in activeProcesses where active.process.isRunning {
            var job = state.jobs[label] ?? AgentJobState()
            job.runningPID = active.process.processIdentifier
            job.runningExecutablePath = active.executablePath
            job.heartbeat = Date()
            job.lastFailure = nil
            state.jobs[label] = job
        }
        for job in runtime.jobs where enabled.contains(job.moduleID) {
            let prior = state.jobs[job.label]
            if job.schedule.kind == .continuous {
                let desiredNonce = healthNonce(for: job.moduleID)
                if let active = activeProcesses[job.label], active.process.isRunning,
                   prior?.healthNonce != desiredNonce {
                    active.process.terminate()
                    continue
                }
                if activeProcesses[job.label]?.process.isRunning != true {
                    try start(job, continuous: true, state: &state)
                }
            } else if activeProcesses[job.label] == nil, RuntimeDuePolicy.isDue(
                job.schedule,
                now: Date(),
                lastAttempt: prior?.lastAttempt
            ) {
                try start(job, continuous: false, state: &state)
            }
        }
        for (label, active) in activeProcesses where active.continuous && !runtime.jobs.contains(where: {
            $0.label == label && enabled.contains($0.moduleID)
        }) {
            if active.process.isRunning { active.process.terminate() }
        }
        try saveState(state)
    }

    private func start(_ job: RuntimeJob, continuous: Bool, state: inout AgentStateFile) throws {
        let executable = bundleURL.appending(path: "Contents/Resources").appending(path: job.executable)
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isExecutable == true else {
            state.jobs[job.label] = AgentJobState(lastAttempt: Date(), lastSuccess: nil, lastFailure: "Bundled executable is missing")
            throw AgentError.missingExecutable(job.label)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = job.arguments
        process.environment = [
            "HOME": fileManager.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "SWITCHBOARD_MODULE_ID": job.moduleID,
            "SWITCHBOARD_RESOURCES_DIR": bundleURL.appending(path: "Contents/Resources").path,
            "SMART_WAKE_HOME": fileManager.homeDirectoryForCurrentUser
                .appending(path: ".config/smart-wake", directoryHint: .isDirectory).path,
            "SMART_WAKE_CODE_DIR": executable.deletingLastPathComponent().path,
            "SWITCHBOARD_HEALTH_NONCE": healthNonce(for: job.moduleID) ?? "",
        ]
        let logs = applicationSupportURL.appending(path: "Logs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safeLabel = job.label.replacingOccurrences(of: ":", with: "-")
        let outputURL = logs.appending(path: "\(safeLabel).log")
        if !fileManager.fileExists(atPath: outputURL.path) { fileManager.createFile(atPath: outputURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: outputURL)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        state.jobs[job.label] = AgentJobState(lastAttempt: Date(), lastSuccess: state.jobs[job.label]?.lastSuccess, lastFailure: nil)
        do {
            try process.run()
            activeProcesses[job.label] = ActiveProcess(
                process: process,
                logHandle: handle,
                continuous: continuous,
                executablePath: executable.path
            )
            state.jobs[job.label]?.runningPID = process.processIdentifier
            state.jobs[job.label]?.runningExecutablePath = executable.path
            state.jobs[job.label]?.heartbeat = Date()
            state.jobs[job.label]?.healthNonce = healthNonce(for: job.moduleID)
            state.jobs[job.label]?.processStartedAt = Date()
        } catch {
            try? handle.close()
            state.jobs[job.label]?.lastFailure = error.localizedDescription
            throw error
        }
    }

    private func reapCompletedProcesses(state: inout AgentStateFile) {
        for (label, active) in activeProcesses where !active.process.isRunning {
            try? active.logHandle.close()
            var job = state.jobs[label] ?? AgentJobState()
            job.runningPID = nil
            job.runningExecutablePath = nil
            job.heartbeat = nil
            if active.process.terminationStatus == 0 {
                job.lastSuccess = Date()
                job.lastFailure = nil
            } else {
                job.lastFailure = "Exited with status \(active.process.terminationStatus)"
            }
            state.jobs[label] = job
            activeProcesses[label] = nil
        }
    }

    private func loadRuntimeManifest() throws -> RuntimeManifest {
        guard let url = Bundle.main.url(forResource: "RuntimeManifest", withExtension: "json") else { throw AgentError.missingManifest }
        return try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
    }

    private func healthNonce(for moduleID: String) -> String? {
        guard LegacySchedulerMigration.isSafeComponent(moduleID) else { return nil }
        let url = applicationSupportURL.appending(path: "Upgrade/health-nonce-\(moduleID).txt")
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0,
              let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private func loadModuleManifest() throws -> ModuleManifest {
        guard let url = Bundle.main.url(forResource: "ModuleManifest", withExtension: "json") else { throw AgentError.missingManifest }
        return try JSONDecoder().decode(ModuleManifest.self, from: Data(contentsOf: url))
    }

    private var stateURL: URL { applicationSupportURL.appending(path: "agent-state.json") }

    private func loadState() throws -> AgentStateFile {
        guard fileManager.fileExists(atPath: stateURL.path) else { return AgentStateFile() }
        return try JSONDecoder().decode(AgentStateFile.self, from: Data(contentsOf: stateURL))
    }

    private func saveState(_ state: AgentStateFile) throws {
        try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

}

enum AgentError: LocalizedError {
    case missingManifest
    case invalidRuntimeManifest
    case missingExecutable(String)
    var errorDescription: String? {
        switch self {
        case .missingManifest: "A Switchboard agent manifest is missing."
        case .invalidRuntimeManifest: "The Switchboard runtime manifest is invalid."
        case .missingExecutable(let label): "The bundled executable for \(label) is missing."
        }
    }
}
