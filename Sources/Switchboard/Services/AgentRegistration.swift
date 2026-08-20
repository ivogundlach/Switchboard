import Foundation
import ServiceManagement

@MainActor
final class AgentRegistration {
    static let plistName = "com.ivogundlach.switchboard.agent.plist"

    var status: SMAppService.Status {
        SMAppService.agent(plistName: Self.plistName).status
    }

    func synchronize(shouldRun: Bool) throws {
        guard CanonicalInstallGate.isCanonical() else { return }
        let service = SMAppService.agent(plistName: Self.plistName)
        if shouldRun, service.status != .enabled, service.status != .requiresApproval {
            try service.register()
        } else if !shouldRun, service.status == .enabled {
            try service.unregister()
        }
    }
}
