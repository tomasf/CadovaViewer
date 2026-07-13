import Foundation
import SwiftUI
import Combine

class Preferences: ObservableObject {
    static let navLibActivationBehaviorKey = "navLibActivationBehavior"
    static let navLibWhitelistedAppsDataKey = "navLibWhitelistedApps"
    static let navLibExcludedAppsDataKey = "navLibExcludedApps"
    static let viewOptionsDataKey = "viewOptions"
    static let documentViewOptionsDataKey = "documentViewOptions"
    static let slicerBundleIdentifierKey = "slicerBundleIdentifier"
    static let removeNonSolidPartsWhenSlicingKey = "removeNonSolidPartsWhenSlicing"
    static let preciseScrollActionKey = "preciseScrollAction"

    enum NavLibAppActivationBehavior: String, RawRepresentable {
        case foregroundOnly
        case always
        case specificApplicationsInForeground
        case allExceptSpecificApplications

        /// Whether this mode is driven by an editable application list (allow- or block-list).
        var usesApplicationList: Bool {
            self == .specificApplicationsInForeground || self == .allExceptSpecificApplications
        }
    }

    enum PreciseScrollAction: String, RawRepresentable {
        case pan
        case zoom
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

    /// Apps the SpaceMouse is claimed *for* in `.specificApplicationsInForeground` mode.
    var navLibWhitelistedApps: [NavLibForegroundApplication] {
        get { self[Self.navLibWhitelistedAppsDataKey] ?? [] }
        set { self[Self.navLibWhitelistedAppsDataKey] = newValue }
    }

    /// Apps the SpaceMouse is *not* claimed for in `.allExceptSpecificApplications` mode (claimed
    /// everywhere else). Kept separate from the allow-list so the two modes don't share state.
    var navLibExcludedApps: [NavLibForegroundApplication] {
        get { self[Self.navLibExcludedAppsDataKey] ?? [] }
        set { self[Self.navLibExcludedAppsDataKey] = newValue }
    }

    var viewOptions: ViewOptions {
        get {
            var options: ViewOptions = self[Self.viewOptionsDataKey] ?? .init()
            // Pre-migration installs stored smoothShading/edgeVisibility as a separate document-wide
            // default under `documentViewOptionsDataKey`; fold it into the per-viewport default once
            // so upgrading doesn't reset a remembered shading/edge choice.
            if let legacy: LegacyDocumentViewOptions = self[Self.documentViewOptionsDataKey] {
                options.smoothShading = legacy.smoothShading
                options.edgeVisibility = legacy.edgeVisibility
                self[Self.viewOptionsDataKey] = options
                defaults.removeObject(forKey: Self.documentViewOptionsDataKey)
            }
            return options
        }
        set { self[Self.viewOptionsDataKey] = newValue }
    }

    /// The bundle identifier of the app to use as the slicer for the "Slice" command. `nil` (the
    /// default) means no slicer is chosen yet, in which case slicing opens Settings instead.
    var slicerBundleIdentifier: String? {
        get { defaults.string(forKey: Self.slicerBundleIdentifierKey) }
        set { defaults.set(newValue, forKey: Self.slicerBundleIdentifierKey) }
    }

    /// Whether non-solid parts (`.context` / `.visual`) are dropped when slicing the whole model.
    /// Defaults to `true`.
    var removeNonSolidPartsWhenSlicing: Bool {
        get { defaults.object(forKey: Self.removeNonSolidPartsWhenSlicingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.removeNonSolidPartsWhenSlicingKey) }
    }

    var preciseScrollAction: PreciseScrollAction {
        get {
            let string = defaults.string(forKey: Self.preciseScrollActionKey) ?? "pan"
            return PreciseScrollAction(rawValue: string) ?? .pan
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.preciseScrollActionKey)
        }
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
