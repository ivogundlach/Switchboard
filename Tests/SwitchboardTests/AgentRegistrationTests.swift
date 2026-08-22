import ServiceManagement
import Testing
@testable import Switchboard

struct AgentRegistrationTests {
    @Test
    func repairsAnApprovedButUnloadedAgent() {
        #expect(AgentRegistration.action(shouldRun: true, status: .enabled, isLoaded: false) == .reregister)
        #expect(AgentRegistration.action(shouldRun: true, status: .enabled, isLoaded: true) == .none)
    }

    @Test
    func preservesApprovalAndDisableSemantics() {
        #expect(AgentRegistration.action(shouldRun: true, status: .requiresApproval, isLoaded: false) == .none)
        #expect(AgentRegistration.action(shouldRun: true, status: .notRegistered, isLoaded: false) == .register)
        #expect(AgentRegistration.action(shouldRun: false, status: .enabled, isLoaded: true) == .unregister)
        #expect(AgentRegistration.action(shouldRun: false, status: .notRegistered, isLoaded: false) == .none)
    }
}
