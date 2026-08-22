import Foundation
import Testing
@testable import Switchboard

struct AgentSchedulerTests {
    @Test
    func shellScriptHealthRequiresTheExactInterpreterAndScriptCommand() {
        let script = "/Applications/Switchboard.app/Contents/Resources/Modules/desktop.smart-wake/bin/smart-wake.sh"
        #expect(ReplacementHealthService.scriptCommandMatches(
            expectedScriptPath: script,
            interpreterPath: "/bin/bash",
            actualCommandLine: "/bin/bash \(script)"
        ))
        #expect(!ReplacementHealthService.scriptCommandMatches(
            expectedScriptPath: script,
            interpreterPath: "/bin/bash",
            actualCommandLine: "/bin/bash /tmp/foreign.sh"
        ))
        #expect(!ReplacementHealthService.scriptCommandMatches(
            expectedScriptPath: script,
            interpreterPath: "/bin/bash",
            actualCommandLine: "/bin/zsh \(script)"
        ))
    }

    @Test
    func intervalHonorsRunAtLoadAndElapsedTime() {
        let schedule = RuntimeSchedule(
            kind: .interval, hour: nil, minute: nil, weekday: nil,
            seconds: 3600, runAtLoad: true, times: nil, startHour: nil, endHour: nil
        )
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(RuntimeDuePolicy.isDue(schedule, now: now, lastAttempt: nil))
        #expect(!RuntimeDuePolicy.isDue(schedule, now: now, lastAttempt: now.addingTimeInterval(-3_599)))
        #expect(RuntimeDuePolicy.isDue(schedule, now: now, lastAttempt: now.addingTimeInterval(-3_600)))
    }

    @Test
    func intervalCanAlsoKeepAnExactWeeklyTrigger() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var schedule = RuntimeSchedule(
            kind: .interval, hour: nil, minute: nil, weekday: nil,
            seconds: 21_600, runAtLoad: true, times: nil, startHour: nil, endHour: nil
        )
        schedule.weeklyAlso = WeeklyTime(weekday: 1, hour: 19, minute: 0)
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 19, minute: 0))!
        #expect(RuntimeDuePolicy.isDue(
            schedule,
            now: sunday,
            lastAttempt: sunday.addingTimeInterval(-60),
            calendar: calendar
        ))
    }

    @Test
    func calendarJobsRunOnlyOncePerMatchingMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 18, minute: 15, second: 20))!
        let schedule = RuntimeSchedule(
            kind: .weekly, hour: 18, minute: 15, weekday: 1,
            seconds: nil, runAtLoad: nil, times: nil, startHour: nil, endHour: nil
        )
        #expect(RuntimeDuePolicy.isDue(schedule, now: now, lastAttempt: nil, calendar: calendar))
        #expect(!RuntimeDuePolicy.isDue(schedule, now: now, lastAttempt: now.addingTimeInterval(-10), calendar: calendar))
        #expect(!RuntimeDuePolicy.isDue(schedule, now: now.addingTimeInterval(60), lastAttempt: nil, calendar: calendar))
    }

    @Test
    func hourlyWindowRejectsOutsideHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let schedule = RuntimeSchedule(
            kind: .hourlyWindow, hour: nil, minute: 0, weekday: nil,
            seconds: nil, runAtLoad: nil, times: nil, startHour: 8, endHour: 22
        )
        let inside = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 8, minute: 0))!
        let outside = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 23, minute: 0))!
        #expect(RuntimeDuePolicy.isDue(schedule, now: inside, lastAttempt: nil, calendar: calendar))
        #expect(!RuntimeDuePolicy.isDue(schedule, now: outside, lastAttempt: nil, calendar: calendar))
    }

    @Test
    func runtimeManifestRejectsTraversalAndUnknownOwners() {
        let continuous = RuntimeSchedule(
            kind: .continuous, hour: nil, minute: nil, weekday: nil,
            seconds: nil, runAtLoad: nil, times: nil, startHour: nil, endHour: nil
        )
        let traversal = RuntimeManifest(schemaVersion: 1, jobs: [
            RuntimeJob(label: "bad", moduleID: "known", executable: "../tool", arguments: [], schedule: continuous),
        ])
        #expect(throws: AgentError.self) {
            try RuntimeManifestValidator.validate(traversal, moduleIDs: ["known"])
        }
        let unknown = RuntimeManifest(schemaVersion: 1, jobs: [
            RuntimeJob(label: "bad", moduleID: "unknown", executable: "Modules/tool", arguments: [], schedule: continuous),
        ])
        #expect(throws: AgentError.self) {
            try RuntimeManifestValidator.validate(unknown, moduleIDs: ["known"])
        }
    }

    @Test
    func moduleSelectionFileRoundTripsAndUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let requested: Set<String> = ["desktop.audio-guard", "systems.memory"]
        try ModuleSelectionFile.save(requested, to: root)
        #expect(try ModuleSelectionFile.load(from: root) == requested)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appending(path: "enabled-modules.json").path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func newlyRegisteredAgentCannotStartModuleUntilSelectionIsPersisted() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = RuntimeManifest(schemaVersion: 1, jobs: [
            RuntimeJob(
                label: "new-module-job",
                moduleID: "newly-enabled",
                executable: "Modules/new-module-job",
                arguments: [],
                schedule: RuntimeSchedule(
                    kind: .continuous, hour: nil, minute: nil, weekday: nil,
                    seconds: nil, runAtLoad: nil, times: nil, startHour: nil, endHour: nil
                )
            ),
        ])

        // AgentRegistration may start the shared agent before migration has
        // finished, but the agent's first tick reads this persisted selection.
        // Until the module ID is written, no job reaches the state/start gate.
        let beforePersistence = try ModuleSelectionFile.load(from: root)
        var stateBeforePersistence = AgentStateFile()
        for job in runtime.jobs where beforePersistence.contains(job.moduleID) {
            if RuntimeDuePolicy.isDue(job.schedule, now: Date(), lastAttempt: stateBeforePersistence.jobs[job.label]?.lastAttempt) {
                stateBeforePersistence.jobs[job.label] = AgentJobState(lastAttempt: Date(), lastSuccess: nil, lastFailure: nil)
            }
        }
        #expect(stateBeforePersistence.jobs.isEmpty)

        try ModuleSelectionFile.save(["newly-enabled"], to: root)
        let afterPersistence = try ModuleSelectionFile.load(from: root)
        #expect(afterPersistence.contains("newly-enabled"))
        #expect(runtime.jobs.filter { afterPersistence.contains($0.moduleID) }.map(\.label) == ["new-module-job"])
    }
}
