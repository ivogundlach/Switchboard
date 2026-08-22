import Testing
@testable import Switchboard

struct LegacyAppRetirementTests {
    @Test
    func acceptsHistoricalLocalCertificateRequirementFromCodesignStandardOutput() {
        let requirement = #"designated => identifier "com.ivogundlach.Kinetics" and certificate leaf = H"12f05e96dc78def756913a2d574ff98f6c5bd485""#
        #expect(LegacyAppRetirement.acceptsDesignatedRequirement(requirement))
    }

    @Test
    func acceptsDeveloperIDTeamRequirementAndRejectsForeignIdentity() {
        let developerID = #"designated => anchor apple generic and identifier "com.ivo.CopyPath" and certificate leaf[subject.OU] = Q2X7X86GYR"#
        let foreign = #"designated => identifier "com.ivo.CopyPath" and certificate leaf = H"0000000000000000000000000000000000000000""#
        #expect(LegacyAppRetirement.acceptsDesignatedRequirement(developerID))
        #expect(!LegacyAppRetirement.acceptsDesignatedRequirement(foreign))
    }
}
