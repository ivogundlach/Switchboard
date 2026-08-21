import AppKit

@MainActor
enum SwitchboardLaunchContext {
    static var backgroundOnly = CommandLine.arguments.contains("--switchboard-background")
    static var warmMigrationID: UUID?
}

if CommandLine.arguments.contains("--self-test") {
    do {
        try SelfTest.run()
        print("Switchboard self-test: PASS")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Switchboard self-test: FAIL — \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--agent") {
    do {
        try SwitchboardAgent().run()
    } catch {
        fputs("Switchboard agent: FAIL — \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--migrate-warm-corners") {
    do {
        try MainActor.assumeIsolated {
            SwitchboardLaunchContext.backgroundOnly = true
            SwitchboardLaunchContext.warmMigrationID = try WarmCornersLiveMigration.prepare()
        }
    } catch {
        fputs("Switchboard Warm Corners migration: FAIL — \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else {
    do {
        try MainActor.assumeIsolated {
            if let recoveryID = try WarmCornersLiveMigration.reconcileBeforeLaunch() {
                SwitchboardLaunchContext.backgroundOnly = true
                SwitchboardLaunchContext.warmMigrationID = recoveryID
            }
        }
    } catch {
        fputs("Switchboard Warm Corners recovery: FAIL — \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
