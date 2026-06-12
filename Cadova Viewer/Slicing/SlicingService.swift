import AppKit
import ViewerCore

/// Drives the "Slice" command: it resolves the user's preferred slicer app, builds a filtered copy of
/// the document (whole model or a single part) using ``ThreeMFItemFilter``, and opens it in the slicer.
/// When no slicer has been chosen yet, it opens Settings instead so the user can pick one.
///
/// `willStart` / `didFinish` bracket the (potentially multi-second) archive-writing work so callers can
/// show a progress indicator. They're only called when work actually begins — not when slicing bails to
/// Settings — and always on the main actor.
enum SlicingService {
    /// Raised when slicing would yield an empty model, so it can be surfaced as an alert instead.
    enum SlicingError: LocalizedError {
        case noSolidParts

        var errorDescription: String? {
            "There are no solid parts to slice."
        }

        var recoverySuggestion: String? {
            "Turn off “Remove non-solid parts when slicing” in Settings, or make some solid parts visible, then try again."
        }
    }

    /// Slices the given candidate `parts` of the model, dropping non-solid ones when the corresponding
    /// preference is on. `totalItemCount` is the model's full build-item count, used to detect when the
    /// kept set covers the whole file (so the original can be opened without any surgery). Pass all parts
    /// for a full slice, or just the visible subset for "Slice Visible Parts".
    static func sliceModel(at sourceURL: URL, parts: [ModelData.Part], totalItemCount: Int, willStart: @escaping () -> Void, didFinish: @escaping () -> Void, errorHandler: @escaping (Error) -> Void) {
        let preferences = Preferences()
        let includedParts: [ModelData.Part]
        if preferences.removeNonSolidPartsWhenSlicing {
            includedParts = parts.filter { $0.semantic == .solid }
            // Filtering left nothing solid — opening an empty 3MF is meaningless, so tell the user.
            guard !includedParts.isEmpty else {
                errorHandler(SlicingError.noSolidParts)
                return
            }
        } else {
            includedParts = parts
            guard !includedParts.isEmpty else { return }
        }
        let keptItemIndices = IndexSet(includedParts.map(\.itemIndex))

        guard let app = resolveSlicerApp() else { return }

        // When the kept items cover the entire source model there's nothing to remove, so skip the
        // surgery and hand the original file straight to the slicer.
        if keptItemIndices == IndexSet(integersIn: 0 ..< totalItemCount) {
            open(sourceURL, in: app, errorHandler: errorHandler)
        } else {
            slice(sourceURL: sourceURL, keptItemIndices: keptItemIndices, nameSuffix: nil, in: app, willStart: willStart, didFinish: didFinish, errorHandler: errorHandler)
        }
    }

    /// Slices a single part, regardless of its semantic — an explicit user choice. Only ever reached
    /// when the model has multiple parts, so surgery is always required.
    static func slicePart(_ part: ModelData.Part, at sourceURL: URL, willStart: @escaping () -> Void, didFinish: @escaping () -> Void, errorHandler: @escaping (Error) -> Void) {
        guard let app = resolveSlicerApp() else { return }
        slice(sourceURL: sourceURL, keptItemIndices: IndexSet(integer: part.itemIndex), nameSuffix: part.name, in: app, willStart: willStart, didFinish: didFinish, errorHandler: errorHandler)
    }

    /// The user's preferred slicer, or `nil` after opening Settings when none is chosen.
    private static func resolveSlicerApp() -> ExternalApplication? {
        let preferences = Preferences()
        guard let bundleIdentifier = preferences.slicerBundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let app = ExternalApplication(url: appURL)
        else {
            openSettings()
            return nil
        }
        return app
    }

    private static func open(_ fileURL: URL, in app: ExternalApplication, errorHandler: @escaping (Error) -> Void) {
        app.open(file: fileURL) { error in
            Task { @MainActor in errorHandler(error) }
        }
    }

    private static func slice(sourceURL: URL, keptItemIndices: IndexSet, nameSuffix: String?, in app: ExternalApplication, willStart: @escaping () -> Void, didFinish: @escaping () -> Void, errorHandler: @escaping (Error) -> Void) {
        willStart()
        Task.detached {
            do {
                let destinationURL = try makeTemporaryURL(for: sourceURL, nameSuffix: nameSuffix)
                try ThreeMFItemFilter.write(from: sourceURL, keepingItemIndices: keptItemIndices, to: destinationURL)
                await MainActor.run {
                    open(destinationURL, in: app, errorHandler: errorHandler)
                    didFinish()
                }
            } catch {
                await MainActor.run {
                    errorHandler(error)
                    didFinish()
                }
            }
        }
    }

    /// A unique temporary location named after the source file (with the part name appended for a
    /// single-part slice) so the slicer shows a meaningful document name.
    private static func makeTemporaryURL(for sourceURL: URL, nameSuffix: String?) throws -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileName = nameSuffix.map { "\(baseName) (\($0))" } ?? baseName

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName).appendingPathExtension("3mf")
    }

    private static func openSettings() {
        NSApp.sendAction(Selector(("showPreferences:")), to: nil, from: nil)
    }
}
