import Foundation
import CadovaLiveLinkCore
import CadovaLiveLinkServer

/// Owns the app's single `LiveLinkServer`, started once at launch and stopped at termination.
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

    /// Called on the main actor for every message received for a path `hasOpenDocument` said yes to,
    /// already converted to `ModelData`. Set this before calling `start()`.
    public var onModelUpdate: (@MainActor (_ path: URL, _ modelData: ModelData, _ token: UUID) -> Void)?

    private var server: LiveLinkServer?

    private init() {}

    /// Starts listening. If another process already owns the LiveLink socket (most likely another
    /// instance of this app, since a Unix domain socket has exactly one listener per path), this
    /// instance simply never receives anything — documents opened here still work normally via the
    /// regular file-watching reload path, just without the LiveLink fast path.
    public func start() {
        guard server == nil else { return }

        let server = LiveLinkServer { [weak self] message in
            let url = URL(fileURLWithPath: message.path)
            Task { @MainActor in
                guard let self, self.hasOpenDocument?(url) == true else { return }
                let modelData = await Task.detached { ModelData(liveLink: message) }.value
                self.onModelUpdate?(url, modelData, message.token)
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
    }
}

public extension ModelData {
    /// The 3MF `<metadata name="...">` name a LiveLink token is stored under, re-exposed here so
    /// app-target code can check it without a direct dependency on the CadovaLiveLink package.
    static let liveLinkTokenMetadataName = LiveLinkMessage.tokenMetadataName
}
