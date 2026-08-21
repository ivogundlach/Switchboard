import Testing
@testable import Switchboard

struct SwitchboardLaunchPolicyTests {
    @Test
    func normalLaunchStartsVisible() {
        let policy = SwitchboardLaunchPolicy(arguments: ["Switchboard"])
        #expect(!policy.backgroundOnly)
    }

    @Test
    func explicitBackgroundAndLoginLaunchesStartHidden() {
        var explicit = SwitchboardLaunchPolicy(arguments: ["Switchboard", "--switchboard-background"])
        #expect(explicit.backgroundOnly)

        var login = SwitchboardLaunchPolicy(arguments: ["Switchboard"])
        login.markLoginItemLaunch(true)
        #expect(login.backgroundOnly)

        explicit.markLoginItemLaunch(false)
        #expect(explicit.backgroundOnly)
    }

    @Test
    func userLaunchPromotesAHiddenInstance() {
        var policy = SwitchboardLaunchPolicy(arguments: ["Switchboard", "--switchboard-background"])
        policy.promoteForUserLaunch()
        #expect(!policy.backgroundOnly)
    }
}
