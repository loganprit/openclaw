import Foundation
import Testing
@testable import OpenClaw

@Suite(.serialized)
@MainActor
struct GatewaySpawnModeTests {
    @Test func defaultsToLaunchd() async {
        await TestIsolation.withUserDefaultsValues([gatewaySpawnModeKey: nil]) {
            #expect(GatewaySpawnMode.current() == .launchd)
        }
    }

    @Test func readsDirectMode() async {
        await TestIsolation.withUserDefaultsValues([gatewaySpawnModeKey: "direct"]) {
            #expect(GatewaySpawnMode.current() == .direct)
        }
    }

    @Test func fallsBackForUnknownValue() async {
        await TestIsolation.withUserDefaultsValues([gatewaySpawnModeKey: "invalid-mode"]) {
            #expect(GatewaySpawnMode.current() == .launchd)
        }
    }
}
