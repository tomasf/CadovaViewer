import Foundation
import SwiftUI
import Combine

class Preferences: ObservableObject {
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

    private let defaults = UserDefaults()

    var objectWillChange: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
    }

    private subscript <T: Codable>(key: String) -> T? {
        get {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    var navLibWhitelistedApps: [NavLibForegroundApplication] {
        get { self[Self.navLibWhitelistedAppsDataKey] ?? [] }
        set { self[Self.navLibWhitelistedAppsDataKey] = newValue }
    }

    var viewOptions: ViewportController.ViewOptions {
        get { self[Self.viewOptionsDataKey] ?? .init() }
        set { self[Self.viewOptionsDataKey] = newValue }
    }

    var navLibActivationBehavior: NavLibAppActivationBehavior {
        get {
            let string = defaults.string(forKey: Self.navLibActivationBehaviorKey) ?? "foregroundOnly"
            return NavLibAppActivationBehavior(rawValue: string) ?? .foregroundOnly
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.navLibActivationBehaviorKey)
        }
    }
}
