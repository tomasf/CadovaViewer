import AppKit
import ViewerCore

/// Drives the "Slice" command: it resolves the user's preferred slicer app, builds a filtered copy of
/// the document (whole model or a single part) using ``ThreeMFItemFilter``, and opens it in the slicer.
/// When no slicer has been chosen yet, it opens Settings instead so the user can pick one.
///
/// Resolution is split from execution: `sliceModel`/`slicePart` synchronously decide what to do and
/// return a runnable ``Operation`` (or `nil` when slicing bails to Settings or has nothing to slice).
/// The caller then `await`s ``Operation/run()`` for the (potentially multi-second) archive-writing
/// work, bracketing a progress indicator around it only when ``Operation/showsProgress`` is `true`.
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

    /// A resolved slice operation ready to be opened in the slicer. `run()` performs any archive
    /// surgery off the main actor before opening the result; `showsProgress` is `true` only when that
    /// surgery happens, so a static "open the original file" hand-off shows no progress indicator.
    struct Operation {
        fileprivate enum Action {
            /// Hand the source file straight to the slicer — the kept items cover the whole model.
            case openOriginal(URL)
            /// Write a filtered copy keeping `keptItemIndices` (named with `nameSuffix`), then open it.
            case surgery(sourceURL: URL, keptItemIndices: IndexSet, nameSuffix: String?)
        }

        fileprivate let app: ExternalApplication
        fileprivate let action: Action

        /// Whether running performs the multi-second archive write worth a progress indicator.
        var showsProgress: Bool {
            if case .surgery = action { return true }
            return false
        }

        func run() async throws {
            switch action {
            case .openOriginal(let fileURL):
                try await app.open(file: fileURL)
            case .surgery(let sourceURL, let keptItemIndices, let nameSuffix):
                let destinationURL = try await Task.detached {
                    let destinationURL = try SlicingService.makeTemporaryURL(for: sourceURL, nameSuffix: nameSuffix)
                    try ThreeMFItemFilter.write(from: sourceURL, keepingItemIndices: keptItemIndices, to: destinationURL)
                    return destinationURL
                }.value
                try await app.open(file: destinationURL)
            }
        }
    }

    /// Resolves a slice of the given candidate `parts` of the model, dropping non-solid ones when the
    /// corresponding preference is on. `totalItemCount` is the model's full build-item count, used to
    /// detect when the kept set covers the whole file (so the original can be opened without any
    /// surgery). Pass all parts for a full slice, or just the visible subset for "Slice Visible Parts".
    /// Returns `nil` when there's nothing to slice or no slicer is configured (Settings is opened);
    /// throws ``SlicingError/noSolidParts`` when filtering leaves the model empty.
    static func sliceModel(at sourceURL: URL, parts: [ModelData.Part], totalItemCount: Int) throws -> Operation? {
        let preferences = Preferences()
        let includedParts: [ModelData.Part]
        if preferences.removeNonSolidPartsWhenSlicing {
            includedParts = parts.filter { $0.semantic == .solid }
            // Filtering left nothing solid — opening an empty 3MF is meaningless, so tell the user.
            guard !includedParts.isEmpty else { throw SlicingError.noSolidParts }
        } else {
            includedParts = parts
            guard !includedParts.isEmpty else { return nil }
        }
        let keptItemIndices = IndexSet(includedParts.map(\.itemIndex))

        guard let app = resolveSlicerApp() else { return nil }

        // When the kept items cover the entire source model there's nothing to remove, so skip the
        // surgery and hand the original file straight to the slicer.
        if keptItemIndices == IndexSet(integersIn: 0 ..< totalItemCount) {
            return Operation(app: app, action: .openOriginal(sourceURL))
        } else {
            return Operation(app: app, action: .surgery(sourceURL: sourceURL, keptItemIndices: keptItemIndices, nameSuffix: nameSuffix(for: includedParts)))
        }
    }

    /// Resolves a slice of a single part, regardless of its semantic — an explicit user choice. Only
    /// ever reached when the model has multiple parts, so surgery is always required. Returns `nil`
    /// when no slicer is configured (Settings is opened).
    static func slicePart(_ part: ModelData.Part, at sourceURL: URL) -> Operation? {
        guard let app = resolveSlicerApp() else { return nil }
        return Operation(app: app, action: .surgery(sourceURL: sourceURL, keptItemIndices: IndexSet(integer: part.itemIndex), nameSuffix: part.name.sanitizedForFilename()))
    }

    /// The temp-filename suffix for a multi-part slice: the part names themselves when there are
    /// few enough to stay readable, otherwise a count — so the slicer's window/tab title says what's
    /// inside without becoming unwieldy for large selections.
    private static func nameSuffix(for includedParts: [ModelData.Part]) -> String? {
        let names = includedParts.map { $0.name.sanitizedForFilename() }
        guard names.count > 1 else { return names.first }

        let joined = ListFormatter.localizedString(byJoining: names)
        return joined.count <= 50 ? joined : "\(names.count) parts"
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

    /// A unique temporary location named after the source file, with the included part name(s)
    /// appended for a partial slice, so the slicer shows a meaningful document name.
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
