import Foundation

@main
struct QuitOnCloseMain {
    static func main() {
        let controller = QuitOnCloseController()
        guard controller.start() else {
            fputs("Quit on Close could not acquire Accessibility event monitoring.\n", stderr)
            exit(EXIT_FAILURE)
        }
        RunLoop.main.run()
    }
}
