import SceneKit
import AppKit
import SwiftUI
import ObjectiveC
import Combine

struct ViewerSceneView: NSViewRepresentable {
    let sceneController: ViewportController

    func makeCoordinator() -> ViewportController {
        sceneController
    }

    func makeNSView(context: Context) -> CustomSceneView {
        context.coordinator.sceneView
    }

    func updateNSView(_ sceneView: CustomSceneView, context: Context) {
        context.coordinator.updateCameraProjection()
    }
}

class CustomSceneView: SCNView {
    var onClick: ((CGPoint) -> Void)? = nil
    var mouseInteractionActive: AnyPublisher<Bool, Never> { mouseInteractionActiveSubject.eraseToAnyPublisher() }
    var mouseRotationPivot: AnyPublisher<SCNVector3?, Never> { mouseRotationPivotSubject.eraseToAnyPublisher() }
    var showContextMenu: AnyPublisher<NSEvent, Never> { contextMenuSubject.eraseToAnyPublisher() }
    weak var sceneController: SceneController?

    private let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    private let contextMenuSubject = PassthroughSubject<NSEvent, Never>()

    override init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(didClick))
        recognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(recognizer)
    }

    @objc
    func didClick(_ recognizer: NSClickGestureRecognizer) {
        onClick?(recognizer.location(in: self))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        NSEvent.overriddenModifierFlags = .option
        mouseDown(with: event)
        NSEvent.overriddenModifierFlags = nil
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas {
            NSEvent.overriddenModifierFlags = .option
            super.scrollWheel(with: event)
            NSEvent.overriddenModifierFlags = nil
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let sceneController, allowsCameraControl else { return }

        super.mouseDown(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)

        if let result = hitTest(localPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber,
            .rootNode: sceneController.modelContainer
        ]).first(where: { $0.node.name != "edges" }) {
            defaultCameraController.target = result.worldCoordinates
        } else {
            defaultCameraController.target = xyPlanePoint(forViewPoint: localPoint)
        }

        mouseInteractionActiveSubject.send(true)
        if NSEvent.modifierFlags.intersection([.shift, .option]) == [] {
            mouseRotationPivotSubject.send(defaultCameraController.target)
        }

        NSCursor.hide()
        var didMove = false
        let endEvent = MouseTracker.track(with: event) { location in
            didMove = true

            if let dragEvent = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: location,
                modifierFlags: [],
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: 1,
                pressure: 0
            ) {
                mouseDragged(with: dragEvent)
            }
        }

        NSCursor.unhide()
        super.mouseUp(with: endEvent)

        mouseRotationPivotSubject.send(nil)
        mouseInteractionActiveSubject.send(false)

        if endEvent.type == .rightMouseUp && !didMove {
            contextMenuSubject.send(endEvent)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @objc
    func copy(_ sender: AnyObject) {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.delegate = self
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        renderer.debugOptions = debugOptions

        let image = renderer.snapshot(atTime: sceneTime, with: CGSize(width: bounds.size.width * 2, height: bounds.size.width * 2), antialiasingMode: antialiasingMode)
        let rect = NSRect(origin: .zero, size: image.size)

        guard let imageRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }

        guard let context = NSGraphicsContext(bitmapImageRep: imageRep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        backgroundColor.setFill()
        rect.fill()
        image.draw(at: .zero, from: rect, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let newImage = NSImage(size: rect.size)
        newImage.addRepresentation(imageRep)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([newImage])
    }
}

extension CustomSceneView: SCNSceneRendererDelegate {
    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let encoder = renderer.currentRenderCommandEncoder as! NSObject
        if encoder.responds(to: NSSelectorFromString("setLineWidth:")) {
            encoder.setValue(2, forKey: "lineWidth")
        }
    }
}
