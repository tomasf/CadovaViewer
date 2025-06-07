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
    weak var sceneController: SceneController?

    private let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)

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
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        _ = CGGetLastMouseDelta() // Clear accumulated delta

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

        var location = event.locationInWindow
        var eventNumber = event.eventNumber

        while true {
            if NSApp.nextEvent(matching: [.leftMouseUp, .rightMouseUp], until: .now.addingTimeInterval(0.001), inMode: .default, dequeue: true) != nil {
                break
            }
            let (deltaX, deltaY) = CGGetLastMouseDelta()
            location.x += CGFloat(deltaX)
            location.y -= CGFloat(deltaY)
            eventNumber += 1

            guard let dragEvent = NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: [], timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0) else { break }
            mouseDragged(with: dragEvent)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()

        if let upEvent = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0) {
            mouseUp(with: upEvent)
        }

        mouseRotationPivotSubject.send(nil)
        mouseInteractionActiveSubject.send(false)
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
