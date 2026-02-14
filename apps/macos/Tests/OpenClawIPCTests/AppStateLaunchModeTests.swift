import Testing
@testable import OpenClaw

@Suite(.serialized)
@MainActor
struct AppStateLaunchModeTests {
    @Test func defaultsToLaunchdAndAlwaysAskWhenUnset() async {
        await TestIsolation.withUserDefaultsValues([
            localGatewayLaunchModeKey: nil,
            childGatewayQuitAlwaysAskKey: nil,
            childGatewayQuitRememberedActionKey: nil,
        ]) {
            let state = AppState(preview: true)
            #expect(state.localGatewayLaunchMode == .launchd)
            #expect(state.childGatewayQuitAlwaysAsk)
            #expect(state.childGatewayQuitRememberedAction == nil)
        }
    }

    @Test func loadsPersistedChildQuitPreferences() async {
        await TestIsolation.withUserDefaultsValues([
            localGatewayLaunchModeKey: AppState.LocalGatewayLaunchMode.child.rawValue,
            childGatewayQuitAlwaysAskKey: false,
            childGatewayQuitRememberedActionKey: AppState.ChildGatewayQuitAction.handoffToLaunchd.rawValue,
        ]) {
            let state = AppState(preview: true)
            #expect(state.localGatewayLaunchMode == .child)
            #expect(!state.childGatewayQuitAlwaysAsk)
            #expect(state.childGatewayQuitRememberedAction == .handoffToLaunchd)
        }
    }
}
