import Foundation
import SwiftUI

struct Preferences {
    static let navLibActivationBehaviorKey = "navLibActivationBehavior"
    static let navLibWhitelistedAppsDataKey = "navLibWhitelistedApps"

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
        guard let data = UserDefaults.standard.data(forKey: Preferences.navLibWhitelistedAppsDataKey) else { return [] }
        return (try? JSONDecoder().decode([Preferences.NavLibForegroundApplication].self, from: data)) ?? []
    }

    static var navLibActivationBehavior: NavLibAppActivationBehavior {
        let string = UserDefaults.standard.string(forKey: Preferences.navLibActivationBehaviorKey) ?? "foregroundOnly"
        return NavLibAppActivationBehavior(rawValue: string) ?? .foregroundOnly
    }
}
