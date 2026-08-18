import Foundation
import CadovaLiveLinkCore
import CadovaLiveLinkServer

/// Owns the app's single `LiveLinkServer`, started once at launch and stopped at termination.
/// Doesn't know about `NSDocument`/`NSDocumentController` itself — the app wires `onModelUpdate` to
/// look up an open document for the given path and apply the given `ModelData`. Deliberately keeps
/// `CadovaLiveLink` (the wire protocol) out of `onModelUpdate`'s signature, so app-target code never
/// needs its own dependency on that package — only `ViewerCore`, which already has one, does.
@MainActor
public final class LiveLinkService {
    public static let shared = LiveLinkService()

    /// Called on the main actor for every message received while the server is running, already
    /// converted to `ModelData`. Set this before calling `start()`.
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
            let modelData = ModelData(liveLink: message)
            let url = URL(fileURLWithPath: message.path)
            Task { @MainActor in
                self?.onModelUpdate?(url, modelData, message.token)
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
