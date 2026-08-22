import Foundation
import ServiceManagement

enum AgentRegistrationAction: Equatable {
    case none
    case register
    case reregister
    case unregister
}

@MainActor
final class AgentRegistration {
    static let plistName = "com.ivogundlach.switchboard.agent.plist"

    var status: SMAppService.Status {
        SMAppService.agent(plistName: Self.plistName).status
    }

    func synchronize(shouldRun: Bool) throws {
        guard CanonicalInstallGate.isCanonical() else { return }
        let service = SMAppService.agent(plistName: Self.plistName)
        switch Self.action(shouldRun: shouldRun, status: service.status, isLoaded: isLoaded()) {
        case .none:
            break
        case .register:
            try service.register()
        case .reregister:
            try service.unregister()
            try service.register()
        case .unregister:
            try service.unregister()
        }
    }

    nonisolated static func action(
        shouldRun: Bool,
        status: SMAppService.Status,
        isLoaded: Bool
    ) -> AgentRegistrationAction {
        if shouldRun {
            if status == .requiresApproval { return .none }
            if status == .enabled { return isLoaded ? .none : .reregister }
            return .register
        }
        return status == .enabled ? .unregister : .none
    }

    private func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.ivogundlach.switchboard.agent"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
