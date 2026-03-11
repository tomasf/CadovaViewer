import QuickLookThumbnailing
import ThreeMF
import AppKit

class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maxSize = request.maximumSize
        let scale = request.scale

        let thumbnailSize = CGSize(
            width: maxSize.width * scale,
            height: maxSize.height * scale
        )

        Task {
            do {
                let cgImage = try await OffscreenRenderer.renderThumbnail(
                    for: url,
                    size: thumbnailSize,
                    includeEdges: false
                )

                let reply = QLThumbnailReply(contextSize: maxSize) { () -> Bool in
                    guard let context = NSGraphicsContext.current?.cgContext else {
                        return false
                    }

                    let imageWidth = CGFloat(cgImage.width) / scale
                    let imageHeight = CGFloat(cgImage.height) / scale

                    let drawRect = CGRect(
                        x: (maxSize.width - imageWidth) / 2,
                        y: (maxSize.height - imageHeight) / 2,
                        width: imageWidth,
                        height: imageHeight
                    )

                    context.draw(cgImage, in: drawRect)
                    return true
                }

                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
