import AppKit

@MainActor
final class WarmCornerRuntime {
    private let hotSize: CGFloat = 6
    private let releaseSize: CGFloat = 40
    private let settings: WarmCornerSettings
    private let indicator = WarmCornerIndicator()
    private let eventMonitor: WarmCornerEventMonitoring

    private var monitorHandles = WarmCornerMonitorHandles()
    private var dwellTask: Task<Void, Never>?
    private var engine = WarmCornerDwellEngine()

    private(set) var isRunning = false

    init(
        settings: WarmCornerSettings,
        eventMonitor: WarmCornerEventMonitoring = AppKitWarmCornerEventMonitor()
    ) {
        self.settings = settings
        self.eventMonitor = eventMonitor
        settings.onPauseChanged = { [weak self] paused in
            if paused { self?.cancelDwell() }
        }
    }

    func start() {
        guard !isRunning else { return }
        monitorHandles = eventMonitor.install { [weak self] in self?.pointerMoved() }
        guard monitorHandles.isComplete else {
            monitorHandles.all.forEach(eventMonitor.remove)
            monitorHandles = WarmCornerMonitorHandles()
            isRunning = false
            return
        }
        isRunning = true
    }

    func stop() {
        monitorHandles.all.forEach(eventMonitor.remove)
        monitorHandles = WarmCornerMonitorHandles()
        dwellTask?.cancel()
        dwellTask = nil
        engine.reset()
        indicator.hide()
        isRunning = false
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation

        let hit = settings.isPaused ? nil : cornerHit(at: location)
        var candidate = hit.map { WarmCornerHit(corner: $0.corner, screenID: screenID($0.screen)) }
        if let fired = engine.fired,
           let screen = NSScreen.screens.first(where: { screenID($0) == fired.screenID }),
           fired.corner.contains(location, on: screen, size: releaseSize) {
            candidate = fired
        }
        let active = candidate.map { settings.action(for: $0.corner).isActive } ?? false
        let delay = hit.map { settings.action(for: $0.corner).delay } ?? 0

        switch engine.pointerMoved(candidate: candidate, isActive: active, delay: delay) {
        case .start:
            if let hit { beginDwell(hit) }
        case .cancel:
            cancelDwell(resetEngine: false)
        case .none:
            break
        }
    }

    private func cornerHit(at location: CGPoint) -> (corner: WarmCorner, screen: NSScreen)? {
        for screen in NSScreen.screens {
            for corner in WarmCorner.allCases where corner.contains(location, on: screen, size: hotSize) {
                return (corner, screen)
            }
        }
        return nil
    }

    private func beginDwell(_ hit: (corner: WarmCorner, screen: NSScreen)) {
        cancelTaskOnly()
        let delay = max(0, settings.action(for: hit.corner).delay)
        if settings.showIndicator {
            indicator.show(corner: hit.corner, screen: hit.screen, duration: delay)
        }
        dwellTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            self?.fire(hit)
        }
    }

    private func fire(_ hit: (corner: WarmCorner, screen: NSScreen)) {
        let current = cornerHit(at: NSEvent.mouseLocation)
        let currentHit = current.map { WarmCornerHit(corner: $0.corner, screenID: screenID($0.screen)) }
        let expected = WarmCornerHit(corner: hit.corner, screenID: screenID(hit.screen))
        guard isRunning, !settings.isPaused,
              engine.timerFired(expected: expected, current: currentHit),
              WarmCornerOpenAction.perform(action: settings.action(for: hit.corner)) else {
            cancelDwell()
            return
        }
        cancelTaskOnly()
        indicator.hide()
    }

    private func cancelTaskOnly() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func cancelDwell(resetEngine: Bool = true) {
        cancelTaskOnly()
        indicator.hide()
        if resetEngine { engine.reset() }
    }

    private func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? "\(screen.frame.origin.x),\(screen.frame.origin.y),\(screen.frame.width),\(screen.frame.height)"
    }
}

@MainActor
protocol WarmCornerEventMonitoring {
    func install(handler: @escaping () -> Void) -> WarmCornerMonitorHandles
    func remove(_ monitorHandle: Any)
}

struct WarmCornerMonitorHandles {
    var global: Any?
    var local: Any?

    var isComplete: Bool { global != nil && local != nil }
    var all: [Any] { [global, local].compactMap { $0 } }
}

@MainActor
final class AppKitWarmCornerEventMonitor: WarmCornerEventMonitoring {
    func install(handler: @escaping () -> Void) -> WarmCornerMonitorHandles {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            Task { @MainActor in handler() }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler()
            return event
        })
        return WarmCornerMonitorHandles(global: global, local: local)
    }

    func remove(_ monitorHandle: Any) {
        NSEvent.removeMonitor(monitorHandle)
    }
}

enum WarmCornerTargetPolicy {
    static func urlToOpen(
        action: WarmCornerAction,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        applicationValidator: (URL) -> Bool = isValidApplicationBundle
    ) -> URL? {
        guard let url = action.appURL,
              fileExists(url.path),
              applicationValidator(url) else { return nil }
        return url
    }

    static func isValidApplicationBundle(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app",
              standardized.resolvingSymlinksInPath() == standardized,
              let values = try? standardized.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
              ]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              let bundle = Bundle(url: standardized),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return false
        }
        return true
    }
}

enum WarmCornerOpenAction {
    static func perform(
        action: WarmCornerAction,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        applicationValidator: (URL) -> Bool = WarmCornerTargetPolicy.isValidApplicationBundle,
        opener: (URL) -> Bool = NSWorkspace.shared.open
    ) -> Bool {
        guard let url = WarmCornerTargetPolicy.urlToOpen(
            action: action,
            fileExists: fileExists,
            applicationValidator: applicationValidator
        ) else {
            return false
        }
        return opener(url)
    }
}

struct WarmCornerHit: Equatable {
    let corner: WarmCorner
    let screenID: String
}

struct WarmCornerDwellEngine {
    enum Command: Equatable {
        case start(delay: Double)
        case cancel
        case none
    }

    private(set) var pending: WarmCornerHit?
    private(set) var fired: WarmCornerHit?

    mutating func pointerMoved(candidate: WarmCornerHit?, isActive: Bool, delay: Double) -> Command {
        if let fired {
            if candidate == fired { return .none }
            self.fired = nil
        }

        guard let candidate, isActive else {
            if pending != nil {
                pending = nil
                return .cancel
            }
            return .none
        }

        if pending == candidate { return .none }
        pending = candidate
        return .start(delay: max(0, delay))
    }

    mutating func timerFired(expected: WarmCornerHit, current: WarmCornerHit?) -> Bool {
        guard pending == expected, current == expected else {
            pending = nil
            return false
        }
        pending = nil
        fired = expected
        return true
    }

    mutating func reset() {
        pending = nil
        fired = nil
    }

}
