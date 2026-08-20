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
        if !UserDefaults.standard.bool(forKey: "switchboard.hasLaunched") {
            UserDefaults.standard.set(true, forKey: "switchboard.hasLaunched")
            showControlCenter()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControlCenter()
        return true
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
}
