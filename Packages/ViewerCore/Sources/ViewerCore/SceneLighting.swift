import AppKit
import CoreGraphics

/// Shared image-based-lighting setup so every renderer (the main viewport, Quick Look preview, and
/// Quick Look thumbnail) gives PBR materials the same reflections.
public enum SceneLighting {
    /// A procedural vertical gray gradient (bright overhead, dark underfoot), used as
    /// `SCNScene.lightingEnvironment.contents`. Reads as soft studio lighting rather than
    /// recognizable scenery, and keeps part shading consistent regardless of model orientation.
    public static let environmentImage: NSImage = makeEnvironmentImage()

    /// SceneKit treats a single image assigned to `lightingEnvironment.contents` as an
    /// equirectangular map (width = longitude, height = latitude), so it needs the usual 2:1 aspect
    /// ratio even though the content only varies top-to-bottom — a badly-proportioned image samples
    /// as a near-flat average instead of a clean gradient.
    private static func makeEnvironmentImage() -> NSImage {
        let width = 256
        let height = 128
        guard let imageRep = NSBitmapImageRep(
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
        ), let context = NSGraphicsContext(bitmapImageRep: imageRep) else {
            return NSImage(size: CGSize(width: width, height: height))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let stops: [(location: CGFloat, gray: CGFloat)] = [(0, 0.95), (0.55, 0.55), (1, 0.12)]
        let colors = stops.map { CGColor(colorSpace: colorSpace, components: [$0.gray, 1])! } as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: stops.map(\.location))!

        context.cgContext.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: height),
            end: .zero,
            options: []
        )

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(imageRep)
        return image
    }
}
