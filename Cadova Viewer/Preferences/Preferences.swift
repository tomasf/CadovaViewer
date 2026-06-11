import Foundation
import SwiftUI
import Combine

class Preferences: ObservableObject {
    static let navLibActivationBehaviorKey = "navLibActivationBehavior"
    static let navLibWhitelistedAppsDataKey = "navLibWhitelistedApps"
    static let viewOptionsDataKey = "viewOptions"
    static let documentViewOptionsDataKey = "documentViewOptions"

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

    var viewOptions: ViewOptions {
        get { self[Self.viewOptionsDataKey] ?? .init() }
        set { self[Self.viewOptionsDataKey] = newValue }
    }

    /// Document-wide defaults (smooth shading, edge visibility) for newly opened documents.
    var documentViewOptions: DocumentViewOptions {
        get { self[Self.documentViewOptionsDataKey] ?? .init() }
        set { self[Self.documentViewOptionsDataKey] = newValue }
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
