import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum QuitOnClosePolicy {
    /// Finder is deliberately never auto-quit, even if an exclusion file is edited.
    static let builtinExclusions: Set<String> = ["com.apple.finder"]

    static func isEligible(
        activationPolicy: NSApplication.ActivationPolicy,
        bundleIdentifier: String?,
        exclusions: Set<String> = []
    ) -> Bool {
        guard activationPolicy == .regular, let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return !exclusions.contains(bundleIdentifier)
            && !builtinExclusions.contains(bundleIdentifier)
    }
}

/// Observes explicit user close actions and quits eligible apps after their last real window closes.
/// It is listen-only: the event tap never changes or consumes the user's input.
final class QuitOnCloseController: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "com.ivogundlach.switchboard.quit-on-close")
    private let systemWide = AXUIElementCreateSystemWide()
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var checking = Set<pid_t>()
    private var exclusions = Set<String>()
    private var exclusionModificationDate = Date.distantPast
    private var commandWTarget: pid_t = 0
    private(set) var isRunning = false

    private let exclusionURL: URL

    init(exclusionURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/quit-on-close/exclude.txt")) {
        self.exclusionURL = exclusionURL
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        reloadExclusions()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventSource = source
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let source = eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventSource = nil
        eventTap = nil
        isRunning = false
        workQueue.sync {
            checking.removeAll()
            commandWTarget = 0
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<QuitOnCloseController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handle(eventType: type, event: event)
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .keyDown:
            if event.flags.contains(.maskCommand), Self.isW(event) {
                commandWTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            }
        case .keyUp:
            if commandWTarget != 0, Self.isW(event) {
                let pid = commandWTarget
                commandWTarget = 0
                workQueue.async { [weak self] in self?.scheduleQuitCheck(pid: pid, reason: "cmd-w") }
            }
        case .leftMouseDown:
            let location = event.location
            workQueue.async { [weak self] in self?.handleClick(at: location) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static func isW(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.keyboardEventKeycode) == 13 { return true }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &chars
        )
        return length > 0 && (chars[0] == 119 || chars[0] == 87)
    }

    private func handleClick(at point: CGPoint) {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == kAXCloseButtonSubrole else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        scheduleQuitCheck(pid: pid, reason: "close button")
    }

    private func reloadExclusions() {
        guard let modificationDate = (try? exclusionURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate,
            modificationDate != exclusionModificationDate,
            let text = try? String(contentsOf: exclusionURL, encoding: .utf8) else { return }
        exclusionModificationDate = modificationDate
        exclusions = Set(text.split(whereSeparator: \.isNewline)
            .map { $0.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    private func scheduleQuitCheck(pid: pid_t, reason: String) {
        reloadExclusions()
        guard !checking.contains(pid),
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              QuitOnClosePolicy.isEligible(
                  activationPolicy: app.activationPolicy,
                  bundleIdentifier: app.bundleIdentifier,
                  exclusions: exclusions
              ) else { return }
        checking.insert(pid)
        quitCheck(app: app, reason: reason, attempt: 1)
    }

    private func quitCheck(app: NSRunningApplication, reason: String, attempt: Int) {
        workQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let pid = app.processIdentifier
            guard !app.isTerminated else {
                checking.remove(pid)
                return
            }
            if Self.realWindowCount(pid) == 0 {
                checking.remove(pid)
                if app.bundleIdentifier == "com.ivogundlach.usagequeue" {
                    _ = app.forceTerminate()
                } else {
                    _ = app.terminate()
                }
            } else if attempt >= 5 {
                checking.remove(pid)
            } else {
                quitCheck(app: app, reason: reason, attempt: attempt + 1)
            }
        }
    }

    private static func realWindowCount(_ pid: pid_t) -> Int {
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var count = 0
        for window in info where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            if layer == 0, alpha > 0 { count += 1 }
        }
        return count + minimizedWindowCount(pid)
    }

    private static func minimizedWindowCount(_ pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return 0 }
        var count = 0
        for window in windows {
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            if minimized as? Bool == true { count += 1 }
        }
        return count
    }
}
