import AppKit
import SceneKit

extension CustomSceneView {
    private var snapshotScale: Double { 2.0 }

    func snapshotImage(withBackground: Bool) -> NSImage? {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.delegate = self
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        renderer.debugOptions = debugOptions

        if withBackground == false {
            viewportController?.privateRoot.isHidden = true
        }

        let image = renderer.snapshot(
            atTime: sceneTime,
            with: CGSize(width: bounds.size.width * snapshotScale, height: bounds.size.height * snapshotScale),
            antialiasingMode: antialiasingMode
        )
        viewportController?.privateRoot.isHidden = false
        let rect = NSRect(origin: .zero, size: image.size)

        guard let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width),
            pixelsHigh: Int(rect.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        guard let context = NSGraphicsContext(bitmapImageRep: imageRep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        if withBackground {
            backgroundColor.setFill()
            rect.fill()
        }
        image.draw(at: .zero, from: rect, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let newImage = NSImage(size: rect.size)
        newImage.addRepresentation(imageRep)
        return newImage
    }

    func copySnapshot(withBackground: Bool) {
        guard let snapshot = snapshotImage(withBackground: withBackground) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([snapshot])
    }

    @IBAction @objc
    func copy(_ sender: Any?) {
        copySnapshot(withBackground: true)
    }

    @IBAction @objc
    func copyWithoutBackground(_ sender: Any?) {
        copySnapshot(withBackground: false)
    }
}

extension CustomSceneView: SCNSceneRendererDelegate {
    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        renderer.currentRenderCommandEncoder?.setLineWidthPrivate(Float(snapshotScale))
    }
}
