import Foundation
import Testing
@testable import Switchboard

struct ModuleOperationalHealthTests {
    @Test
    func everyManifestModuleHasAnExplicitOperationalProbeContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            ModuleManifest.self,
            from: Data(contentsOf: root.appending(path: "Sources/Switchboard/Resources/ModuleManifest.json"))
        )
        #expect(manifest.modules.count == 17)
        for module in manifest.modules {
            #expect(
                ModuleOperationalHealthService.probes(for: module.id) != nil,
                "Missing health contract for \(module.id)"
            )
        }
    }

    @Test
    func commandOwnershipFailsClosedAndAcceptsOnlyExactBundleSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "switchboard-health-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let bundle = root.appending(path: "Switchboard.app", directoryHint: .isDirectory)
        let source = bundle.appending(path: "Contents/Resources/Modules/test.module/bin/tool")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: source)
        try FileManager.default.createDirectory(at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)

        let missing = ModuleOperationalHealthService.activationReady(
            moduleID: "test.module",
            commandNames: ["tool"],
            serviceNames: [],
            ownsScheduledJobs: false,
            agentEnabled: false,
            bundleURL: bundle,
            homeDirectory: home
        )
        #expect(!missing.ready)

        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".local/bin/tool"),
            withDestinationURL: source
        )
        let owned = ModuleOperationalHealthService.activationReady(
            moduleID: "test.module",
            commandNames: ["tool"],
            serviceNames: [],
            ownsScheduledJobs: false,
            agentEnabled: false,
            bundleURL: bundle,
            homeDirectory: home
        )
        #expect(owned.ready)
    }
}
