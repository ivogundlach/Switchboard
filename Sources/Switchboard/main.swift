import AppKit
import ApplicationServices

struct SwitchboardLaunchPolicy {
    private(set) var backgroundOnly: Bool

    init(arguments: [String]) {
        backgroundOnly = arguments.contains("--switchboard-background")
    }

    mutating func markLoginItemLaunch(_ launchedAsLoginItem: Bool) {
        if launchedAsLoginItem { backgroundOnly = true }
    }

    mutating func forceBackgroundOnly() {
        backgroundOnly = true
    }

    mutating func promoteForUserLaunch() {
        backgroundOnly = false
    }
}

@MainActor
enum SwitchboardLaunchContext {
    private static var policy = SwitchboardLaunchPolicy(arguments: CommandLine.arguments)
    static var backgroundOnly: Bool { policy.backgroundOnly }
    static var warmMigrationID: UUID?

    static func markLoginItemLaunch(_ launchedAsLoginItem: Bool) {
        policy.markLoginItemLaunch(launchedAsLoginItem)
    }

    static func forceBackgroundOnly() {
        policy.forceBackgroundOnly()
    }

    static func promoteForUserLaunch() {
        policy.promoteForUserLaunch()
    }
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

if CommandLine.arguments.contains("--accessibility-status") {
    let trusted = AXIsProcessTrusted()
    print("{\"accessibilityTrusted\":\(trusted)}")
    exit(trusted ? EXIT_SUCCESS : EXIT_FAILURE)
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
            SwitchboardLaunchContext.forceBackgroundOnly()
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
                SwitchboardLaunchContext.forceBackgroundOnly()
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
