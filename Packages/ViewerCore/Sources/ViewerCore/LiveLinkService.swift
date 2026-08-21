import Foundation
import CadovaLiveLinkCore
import CadovaLiveLinkHost

/// Owns the app's single `LiveLinkHost`, started once at launch and stopped at termination.
/// Doesn't know about `NSDocument`/`NSDocumentController` itself — the app wires `hasOpenDocument`
/// and `onModelUpdate` to look up an open document for a given path. Deliberately keeps
/// `CadovaLiveLink` (the wire protocol) out of both signatures, so app-target code never needs its
/// own dependency on that package — only `ViewerCore`, which already has one, does.
@MainActor
public final class LiveLinkService {
    public static let shared = LiveLinkService()

    /// Checked on the main actor for every message received, before it's converted to `ModelData` —
    /// that conversion builds real `SCNGeometry`, edge lines, and a cap solid, proportional to mesh
    /// size, which is wasted work for a push nothing will ever use. Set this before calling `start()`.
    public var hasOpenDocument: (@MainActor (_ path: URL) -> Bool)?

    /// Called on the main actor once `hasOpenDocument` says yes, before the (potentially multi-
    /// second, for a large model) `ModelData` conversion begins — mirrors the file-loading path
    /// showing its loading indicator before parsing starts, not just once new geometry is ready.
    /// Set this before calling `start()`.
    public var onLoadingStarted: (@MainActor (_ path: URL) -> Void)?

    /// Called on the main actor for every message received for a path `hasOpenDocument` said yes to,
    /// already converted to `ModelData`. Set this before calling `start()`.
    public var onModelUpdate: (@MainActor (_ path: URL, _ modelData: ModelData, _ buildUUID: UUID) -> Void)?

    private var server: LiveLinkHost?

    private init() {}

    /// Starts listening. If another process already owns the LiveLink socket (most likely another
    /// instance of this app, since a Unix domain socket has exactly one listener per path), this
    /// instance simply never receives anything — documents opened here still work normally via the
    /// regular file-watching reload path, just without the LiveLink fast path.
    public func start() {
        guard server == nil else { return }

        let server = LiveLinkHost { [weak self] message in
            let url = URL(fileURLWithPath: message.path)
            Task { @MainActor in
                guard let self, self.hasOpenDocument?(url) == true else { return }
                self.onLoadingStarted?(url)
                let modelData = await Task.detached { await ModelData(liveLink: message) }.value
                self.onModelUpdate?(url, modelData, message.buildUUID)
            }
        }

        do {
            try server.start()
            self.server = server
        } catch {
            print("LiveLink: couldn't start listener (\(error)); continuing without it.")
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: LiveLinkEndpoint.statePath)
    }

    /// Rewrites the declared LiveLink host state with the given set of open document paths, so a
    /// sender (`LiveLinkClient.isInterested(inPath:)`) can tell up front whether it's worth building
    /// a message for a given path, without connecting to ask. Call this whenever the app's set of
    /// open documents changes — the app owns that knowledge, this type deliberately doesn't (see the
    /// type comment). Safe to call before `start()`.
    public func updateOpenDocuments(paths: [String]) {
        let state = LiveLinkHostState(
            protocolVersion: LiveLinkFraming.protocolVersion,
            minimumCompatibleProtocolVersion: LiveLinkFraming.protocolVersion,
            interestedPaths: paths,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        do {
            try state.write(toFileAt: LiveLinkEndpoint.statePath)
        } catch {
            print("LiveLink: couldn't write host state file (\(error))")
        }
    }
}
