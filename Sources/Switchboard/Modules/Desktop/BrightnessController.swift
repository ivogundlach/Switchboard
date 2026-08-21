import CoreGraphics
import Darwin
import Foundation
import Observation

enum BrightnessResult: Equatable {
    case applied(level: Double, displayCount: Int)
    case failed(String)
}

protocol BrightnessDisplayAPI {
    func activeDisplayIDs() -> [CGDirectDisplayID]
    func setBrightness(_ level: Float, for displayID: CGDirectDisplayID) -> Bool
}

/// Controls all active displays through macOS's native display service.
@Observable
final class BrightnessController {
    private static let dayLevelKey = "switchboard.brightness.day-level"
    private static let nightLevelKey = "switchboard.brightness.night-level"

    private(set) var dayLevel: Double
    private(set) var nightLevel: Double
    private let displayAPI: BrightnessDisplayAPI
    @ObservationIgnored
    private let defaults: UserDefaults
    private(set) var isRunning = false

    init(
        dayLevel: Double? = nil,
        nightLevel: Double? = nil,
        defaults: UserDefaults = .standard,
        displayAPI: BrightnessDisplayAPI = DynamicBrightnessDisplayAPI()
    ) {
        self.defaults = defaults
        let savedDay = defaults.object(forKey: Self.dayLevelKey) as? Double
        let savedNight = defaults.object(forKey: Self.nightLevelKey) as? Double
        self.dayLevel = Self.clamped(dayLevel ?? savedDay ?? 1.0)
        self.nightLevel = Self.clamped(nightLevel ?? savedNight ?? 0.3)
        self.displayAPI = displayAPI
    }

    func start() { isRunning = true }

    func stop() { isRunning = false }

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return value.sign == .minus ? 0 : 1 }
        return min(1, max(0, value))
    }

    func setDayLevel(_ value: Double) {
        dayLevel = Self.clamped(value)
        defaults.set(dayLevel, forKey: Self.dayLevelKey)
    }

    func setNightLevel(_ value: Double) {
        nightLevel = Self.clamped(value)
        defaults.set(nightLevel, forKey: Self.nightLevelKey)
    }

    @discardableResult
    func setDay() -> BrightnessResult { setBrightness(dayLevel) }

    @discardableResult
    func setNight() -> BrightnessResult { setBrightness(nightLevel) }

    @discardableResult
    func setBrightness(_ value: Double) -> BrightnessResult {
        let level = Self.clamped(value)
        let displays = displayAPI.activeDisplayIDs()
        guard !displays.isEmpty else { return .failed("No active displays are available") }

        var failedDisplays = 0
        for display in displays where !displayAPI.setBrightness(Float(level), for: display) {
            failedDisplays += 1
        }
        guard failedDisplays == 0 else {
            return .failed("Brightness could not be set on \(failedDisplays) active display(s)")
        }
        return .applied(level: level, displayCount: displays.count)
    }
}

/// Private display APIs are intentionally resolved at runtime so Switchboard does not link
/// against an undocumented framework at build time.
final class DynamicBrightnessDisplayAPI: BrightnessDisplayAPI {
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let setter: SetBrightnessFunction?

    init() {
        let candidates = [
            ("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", "DisplayServicesSetBrightness"),
            ("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", "CoreDisplay_Display_SetUserBrightness"),
            ("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", "CoreDisplay_Display_SetUserBrightness"),
        ]
        var loadedHandle: UnsafeMutableRawPointer?
        var loadedSetter: SetBrightnessFunction?
        for (path, symbol) in candidates {
            guard let candidate = dlopen(path, RTLD_LAZY),
                  let address = dlsym(candidate, symbol) else { continue }
            loadedHandle = candidate
            loadedSetter = unsafeBitCast(address, to: SetBrightnessFunction.self)
            break
        }
        handle = loadedHandle
        setter = loadedSetter
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    func setBrightness(_ level: Float, for displayID: CGDirectDisplayID) -> Bool {
        guard let setter else { return false }
        setter(displayID, level)
        return true
    }
}
