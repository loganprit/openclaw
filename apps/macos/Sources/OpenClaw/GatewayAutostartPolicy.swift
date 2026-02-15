import Foundation

enum GatewayAutostartPolicy {
    static func shouldStartGateway(mode: AppState.ConnectionMode, paused: Bool) -> Bool {
        mode == .local && !paused
    }

    static func shouldEnsureLaunchAgent(
        mode: AppState.ConnectionMode,
        launchMode: AppState.LocalGatewayLaunchMode,
        paused: Bool) -> Bool
    {
        self.shouldStartGateway(mode: mode, paused: paused) && launchMode == .launchd
    }
}
