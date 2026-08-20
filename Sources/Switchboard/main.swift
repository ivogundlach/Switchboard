import AppKit

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

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
