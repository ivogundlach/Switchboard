import CoreGraphics
import Foundation
import Testing
@testable import Switchboard

struct DesktopControllerTests {
    @Test
    func brightnessLevelsPersistWithoutChangingDisplays() throws {
        let suite = "SwitchboardTests.Brightness.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = BrightnessController(defaults: defaults, displayAPI: RecordingBrightnessAPI(displays: []))
        first.setDayLevel(0.8)
        first.setNightLevel(0.2)

        let restored = BrightnessController(defaults: defaults, displayAPI: RecordingBrightnessAPI(displays: []))
        #expect(restored.dayLevel == 0.8)
        #expect(restored.nightLevel == 0.2)
    }

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

    @Test
    func copyPathEnableAndDisableUseOnlyTheCanonicalExtensionIdentity() throws {
        let runner = RecordingCopyPathRunner()
        let controller = CopyPathController(commandRunner: runner)
        let canonical = CopyPathController.canonicalAppURL

        try controller.enable(bundleURL: canonical)
        try controller.disable(bundleURL: canonical)

        #expect(runner.calls == [
            .init(executable: CopyPathController.pluginkitPath, arguments: ["-a", CopyPathController.canonicalExtensionURL.path]),
            .init(executable: CopyPathController.pluginkitPath, arguments: ["-e", "use", "-i", CopyPathController.extensionIdentifier]),
            .init(executable: CopyPathController.pluginkitPath, arguments: ["-e", "disable", "-i", CopyPathController.extensionIdentifier]),
        ])
    }

    @Test
    func copyPathRejectsNonCanonicalBundleBeforeRunningPluginkit() {
        let runner = RecordingCopyPathRunner()
        let controller = CopyPathController(commandRunner: runner)

        #expect(throws: CopyPathActivationError.self) {
            try controller.enable(bundleURL: URL(fileURLWithPath: "/tmp/Switchboard.app"))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test
    func kineticsReadinessChecksNestedIdentityWithoutLaunchingAnything() throws {
        let bundleURL = try makeFakeKineticsBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let controller = KineticsCompanionController()
        controller.refresh(bundleURL: bundleURL)

        #expect(controller.isReady)
        #expect(controller.lastFailure == nil)
        #expect(FileManager.default.fileExists(
            atPath: bundleURL.appending(path: KineticsCompanionController.companionRelativePath)
                .appending(path: KineticsCompanionController.executableRelativePath).path
        ))
    }

    @Test
    func kineticsReadinessRejectsLegacyLoginLauncherWithoutCreatingState() throws {
        let bundleURL = try makeFakeKineticsBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let legacyURL = bundleURL.appending(path: KineticsCompanionController.companionRelativePath)
            .appending(path: "Contents/Library/LoginItems/Kinetics Login Launcher.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)

        let controller = KineticsCompanionController()
        controller.refresh(bundleURL: bundleURL)

        #expect(!controller.isReady)
        #expect(controller.lastFailure == KineticsCompanionError.loginLauncherBundled.localizedDescription)
    }
}

private func makeFakeKineticsBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "switchboard-kinetics-\(UUID().uuidString).app", directoryHint: .isDirectory)
    let companion = root.appending(path: KineticsCompanionController.companionRelativePath, directoryHint: .isDirectory)
    let executable = companion.appending(path: KineticsCompanionController.executableRelativePath)
    let resources = companion.appending(path: "Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": KineticsCompanionController.bundleIdentifier,
        "CFBundleExecutable": "Kinetics",
        "LSUIElement": true,
        "LSMinimumSystemVersion": "26.0",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: companion.appending(path: "Contents/Info.plist"))
    try Data("fake executable".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try Data("fake icon".utf8).write(to: resources.appending(path: "AppIcon.icns"))
    return root
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

private final class RecordingCopyPathRunner: CopyPathCommandRunning {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(executable: String, arguments: [String]) throws -> CopyPathCommandResult {
        calls.append(.init(executable: executable, arguments: arguments))
        return CopyPathCommandResult(status: 0, stdout: "", stderr: "")
    }
}
