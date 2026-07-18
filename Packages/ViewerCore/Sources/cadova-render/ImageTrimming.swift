import Foundation
import AppKit

/// Crops a rendered image down to the bounding box of its non-background content, for a tight,
/// margin-free result regardless of how much headroom the camera framing left.
enum ImageTrimming {
    /// `backgroundColor` is the solid color the scene was rendered against, or `nil` if the render
    /// was transparent (in which case pixels are classified by alpha instead of color distance).
    static func trim(_ image: NSImage, backgroundColor: NSColor?, padding: Int) -> NSImage {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let data = bitmap.bitmapData
        else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let backgroundComponents: (UInt8, UInt8, UInt8)? = backgroundColor
            .flatMap { $0.usingColorSpace(.deviceRGB) }
            .map {
                (
                    UInt8(($0.redComponent * 255).rounded()),
                    UInt8(($0.greenComponent * 255).rounded()),
                    UInt8(($0.blueComponent * 255).rounded())
                )
            }
        let colorTolerance = 10

        let bytesPerRow = bitmap.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let pixelOffset = rowOffset + x * 4
                let isContent: Bool
                if let background = backgroundComponents {
                    isContent = abs(Int(data[pixelOffset]) - Int(background.0)) > colorTolerance
                        || abs(Int(data[pixelOffset + 1]) - Int(background.1)) > colorTolerance
                        || abs(Int(data[pixelOffset + 2]) - Int(background.2)) > colorTolerance
                } else {
                    isContent = data[pixelOffset + 3] > 0
                }

                if isContent {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        // No content found (e.g. an empty model) - leave the render untouched rather than producing
        // a zero-size image.
        guard maxX >= minX, maxY >= minY else { return image }

        minX = Swift.max(0, minX - padding)
        minY = Swift.max(0, minY - padding)
        maxX = Swift.min(width - 1, maxX + padding)
        maxY = Swift.min(height - 1, maxY + padding)

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let sourceCGImage = bitmap.cgImage,
              let croppedCGImage = sourceCGImage.cropping(to: cropRect)
        else { return image }

        return NSImage(cgImage: croppedCGImage, size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height))
    }
}
