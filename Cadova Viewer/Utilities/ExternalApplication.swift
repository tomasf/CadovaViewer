import Cocoa

struct ExternalApplication {
    let url: URL
    let bundleIdentifier: String

    init?(url: URL) {
        self.url = url
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        self.bundleIdentifier = bundleID
    }

    var name: String {
        FileManager().displayName(atPath: url.path(percentEncoded: false))
    }

    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

extension ExternalApplication {
    static func appsAbleToOpen(url: URL) -> [ExternalApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
            .compactMap(ExternalApplication.init)
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
    }

    func open(file fileURL: URL, errorHandler: @escaping (Error) -> ()) {
        Task {
            do {
                try await NSWorkspace.shared.open([fileURL], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                errorHandler(error)
            }
        }
    }
}
