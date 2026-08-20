import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ModuleStore()
    private var statusItem: NSStatusItem?
    private var controlWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        Task { await store.resumePersistedModules() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControlCenter()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let module = store.module(id: "files.auto-install-dmg"), store.isEnabled(module) else {
            store.lastError = "Enable AutoInstall DMG in Switchboard before opening disk images with it."
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Switchboard/AutoInstall DMG", directoryHint: .isDirectory)
            let queue = support.appending(path: "queue", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: queue,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var accepted = 0
            for filename in filenames where filename.lowercased().hasSuffix(".dmg") {
                let source = URL(fileURLWithPath: filename)
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let job = queue.appending(path: "\(Date().timeIntervalSince1970)-\(UUID().uuidString).job")
                try Data(source.path.utf8).write(to: job, options: .atomic)
                accepted += 1
            }
            guard accepted > 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
            try launchAutoInstallWorker(supportURL: support)
            sender.reply(toOpenOrPrint: .success)
        } catch {
            store.lastError = "AutoInstall DMG could not queue the disk image: \(error.localizedDescription)"
            sender.reply(toOpenOrPrint: .failure)
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: "Switchboard")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let openItem = menu.addItem(withTitle: "Open Switchboard", action: #selector(showControlCenter), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Switchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        item.menu = menu
        statusItem = item
    }

    @objc private func showControlCenter() {
        if controlWindow == nil {
            let root = RootView(store: store).focusEffectDisabled()
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Switchboard"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1080, height: 720))
            window.minSize = NSSize(width: 940, height: 640)
            window.center()
            controlWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    private func launchAutoInstallWorker(supportURL: URL) throws {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let worker = resources.appending(path: "Modules/files.auto-install-dmg/bin/auto-install-dmg-worker")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        process.executableURL = worker
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "AIDMG_SUPPORT_DIR": supportURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
