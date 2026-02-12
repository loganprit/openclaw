import Foundation

enum GatewaySpawnMode: String, CaseIterable, Identifiable {
    case launchd
    case direct

    static let `default`: GatewaySpawnMode = .launchd

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .launchd: "launchd (persistent)"
        case .direct: "direct child process"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> GatewaySpawnMode {
        guard
            let raw = defaults.string(forKey: gatewaySpawnModeKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            let mode = GatewaySpawnMode(rawValue: raw)
        else {
            return .default
        }
        return mode
    }
}
