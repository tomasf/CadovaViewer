import Foundation
import SwiftUI

struct Preferences {
    static let navLibActivationBehaviorKey = "navLibActivationBehavior"
    static let navLibWhitelistedAppsDataKey = "navLibWhitelistedApps"
    static let viewOptionsDataKey = "viewOptions"

    enum NavLibAppActivationBehavior: String, RawRepresentable {
        case foregroundOnly
        case always
        case specificApplicationsInForeground
    }

    struct NavLibForegroundApplication: Codable, Hashable {
        var bundleIdentifier: String
        let displayName: String
    }

    static var navLibWhitelistedApps: [NavLibForegroundApplication] {
        guard let data = UserDefaults.standard.data(forKey: navLibWhitelistedAppsDataKey) else { return [] }
        return (try? JSONDecoder().decode([Preferences.NavLibForegroundApplication].self, from: data)) ?? []
    }

    static var navLibActivationBehavior: NavLibAppActivationBehavior {
        let string = UserDefaults.standard.string(forKey: navLibActivationBehaviorKey) ?? "foregroundOnly"
        return NavLibAppActivationBehavior(rawValue: string) ?? .foregroundOnly
    }

    static var viewOptions: ViewportController.ViewOptions {
        get {
            guard let data = UserDefaults.standard.data(forKey: viewOptionsDataKey) else { return .init() }
            return (try? JSONDecoder().decode(ViewportController.ViewOptions.self, from: data)) ?? .init()
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: viewOptionsDataKey)
        }
    }
}
