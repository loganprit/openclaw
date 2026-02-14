import Testing
@testable import OpenClaw

@Suite(.serialized)
struct GatewayAutostartPolicyTests {
    @Test func startsGatewayOnlyWhenLocalAndNotPaused() {
        #expect(GatewayAutostartPolicy.shouldStartGateway(mode: .local, paused: false))
        #expect(!GatewayAutostartPolicy.shouldStartGateway(mode: .local, paused: true))
        #expect(!GatewayAutostartPolicy.shouldStartGateway(mode: .remote, paused: false))
        #expect(!GatewayAutostartPolicy.shouldStartGateway(mode: .unconfigured, paused: false))
    }

    @Test func ensuresLaunchAgentWhenLocalAndNotAttachOnly() {
        #expect(GatewayAutostartPolicy.shouldEnsureLaunchAgent(
            mode: .local,
            launchMode: .launchd,
            paused: false))
        #expect(!GatewayAutostartPolicy.shouldEnsureLaunchAgent(
            mode: .local,
            launchMode: .launchd,
            paused: true))
        #expect(!GatewayAutostartPolicy.shouldEnsureLaunchAgent(
            mode: .local,
            launchMode: .child,
            paused: false))
        #expect(!GatewayAutostartPolicy.shouldEnsureLaunchAgent(
            mode: .remote,
            launchMode: .launchd,
            paused: false))
    }
}
