import Foundation

/// Cadova Viewer used to sandbox itself, which redirected `UserDefaults` into
/// `~/Library/Containers/<bundle-id>/Data/Library/Preferences/` instead of the real
/// `~/Library/Preferences/`. Copies an existing sandboxed install's settings into the real
/// location, once, so someone updating from an old version doesn't see their settings silently
/// reset to defaults.
///
/// Reading that old file is the same category of "read file content out of another app's
/// sandboxed container" access that used to make LiveLink prompt on every single rebuild (see
/// `LiveLinkHostState` in CadovaLiveLink) — but this runs once per user, on the first launch after
/// updating, against the app's stable shipped code identity, not a binary rebuilt on every run. A
/// one-time permission prompt for a legitimate reason is normal; repeating on every launch, which
/// is what made LiveLink's case a real problem, isn't what happens here.
enum PreferencesMigration {
    private static let didRunKey = "didMigrateFromSandboxedPreferences"

    /// Must run before anything reads `Preferences()`/`UserDefaults.standard` — the first document
    /// window's `ViewportController` already does, which can happen as early as Launch Services
    /// handing this process a file to open, before normal app-launch code runs. See where this is
    /// called from in `AppDelegate` for how that's ensured.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRunKey) else { return }
        defer { defaults.set(true, forKey: didRunKey) }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "se.tomasf.CadovaViewer"
        let oldPath = NSHomeDirectory() + "/Library/Containers/\(bundleIdentifier)/Data/Library/Preferences/\(bundleIdentifier).plist"
        guard let oldValues = NSDictionary(contentsOfFile: oldPath) as? [String: Any] else { return }

        for (key, value) in oldValues {
            defaults.set(value, forKey: key)
        }
    }
}
