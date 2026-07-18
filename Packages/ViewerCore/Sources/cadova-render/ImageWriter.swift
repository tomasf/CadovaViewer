import Foundation
import AppKit

enum ImageWriter {
    static func write(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw RenderError.imageEncodingFailed
        }

        let fileType: NSBitmapImageRep.FileType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        guard let data = bitmap.representation(using: fileType, properties: [:]) else {
            throw RenderError.imageEncodingFailed
        }

        try data.write(to: url)
    }
}
