import CoreGraphics
import Testing
@testable import Switchboard

struct DesktopControllerTests {
    @Test
    func brightnessClampsToDisplayRange() {
        #expect(BrightnessController.clamped(-0.5) == 0)
        #expect(BrightnessController.clamped(0.4) == 0.4)
        #expect(BrightnessController.clamped(1.5) == 1)
    }

    @Test
    func brightnessAppliesToEveryActiveDisplay() {
        let api = RecordingBrightnessAPI(displays: [1, 2])
        let controller = BrightnessController(displayAPI: api)

        let result = controller.setBrightness(1.4)

        #expect(result == .applied(level: 1, displayCount: 2))
        #expect(api.values.map(\.0) == [1, 2])
        #expect(api.values.map(\.1) == [1, 1])
    }

    @Test
    func quitEligibilityRequiresRegularNonExcludedBundle() {
        #expect(QuitOnClosePolicy.isEligible(
            activationPolicy: .regular,
            bundleIdentifier: "com.example.Editor"
        ))
        #expect(!QuitOnClosePolicy.isEligible(
            activationPolicy: .accessory,
            bundleIdentifier: "com.example.Editor"
        ))
        #expect(!QuitOnClosePolicy.isEligible(
            activationPolicy: .regular,
            bundleIdentifier: "com.example.Editor",
            exclusions: ["com.example.Editor"]
        ))
        #expect(!QuitOnClosePolicy.isEligible(
            activationPolicy: .regular,
            bundleIdentifier: "com.apple.finder"
        ))
    }

    @Test
    func controllerStartAndStopAreIdempotent() {
        let brightness = BrightnessController(displayAPI: RecordingBrightnessAPI(displays: []))
        brightness.start()
        brightness.start()
        #expect(brightness.isRunning)
        brightness.stop()
        brightness.stop()
        #expect(!brightness.isRunning)

        #expect(brightness.setBrightness(-1) == .failed("No active displays are available"))

        let audio = AudioDisconnectGuardController()
        audio.stop()
        audio.stop()
        #expect(!audio.isRunning)
    }
}

private final class RecordingBrightnessAPI: BrightnessDisplayAPI {
    let displays: [CGDirectDisplayID]
    private(set) var values: [(CGDirectDisplayID, Float)] = []

    init(displays: [CGDirectDisplayID]) { self.displays = displays }

    func activeDisplayIDs() -> [CGDirectDisplayID] { displays }

    func setBrightness(_ level: Float, for displayID: CGDirectDisplayID) -> Bool {
        values.append((displayID, level))
        return true
    }
}
