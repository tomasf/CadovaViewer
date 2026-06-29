import Cocoa
import UniformTypeIdentifiers

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
    /// The 3MF package content type the viewer declares (`org.3mf.threemfpackage`), falling back to the
    /// type registered for the `.3mf` extension.
    static var threeMFContentType: UTType {
        UTType("org.3mf.threemfpackage") ?? UTType(filenameExtension: "3mf") ?? .data
    }

    static func appsAbleToOpen(url: URL) -> [ExternalApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
            .compactMap(ExternalApplication.init)
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
    }

    /// The apps registered to open a given content type. Used by Settings to populate the slicer
    /// picker when no document is open, mirroring `appsAbleToOpen(url:)`.
    static func appsAbleToOpen(contentType: UTType) -> [ExternalApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: contentType)
            .compactMap(ExternalApplication.init)
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
    }

    func open(file fileURL: URL) async throws {
        try await NSWorkspace.shared.open([fileURL], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
