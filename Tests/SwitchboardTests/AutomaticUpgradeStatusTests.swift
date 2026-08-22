import Foundation
import Testing
@testable import Switchboard

struct AutomaticUpgradeStatusTests {
    @Test
    func statusStorePersistsPrivateCompleteComponentLedger() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "switchboard-auto-upgrade-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let component = AutomaticUpgradeComponentRecord(
            moduleID: "systems.memory",
            componentID: "memory-corpus-backup",
            displayName: "Memory corpus backup",
            kind: .launchAgent,
            disposition: .migrate,
            detection: .enabled,
            detail: "Detected"
        )
        let status = AutomaticUpgradeStatus(
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            phase: .waitingForPermissions,
            selectedModuleIDs: ["systems.memory"],
            components: [component],
            permissionBlockers: ["Required permission"],
            moduleResults: [:],
            failure: nil
        )
        let store = AutomaticUpgradeStatusStore(applicationSupportURL: root)
        try store.save(status)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(AutomaticUpgradeStatus.self, from: Data(contentsOf: store.fileURL))
        #expect(saved == status)
        #expect(saved.components == [component])
    }
}
