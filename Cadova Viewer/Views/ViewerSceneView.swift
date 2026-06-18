import SceneKit
import AppKit
import SwiftUI
import ObjectiveC
import Combine
import Carbon.HIToolbox
import ViewerCore

struct ViewerSceneView: NSViewRepresentable {
    let viewportController: ViewportController

    func makeCoordinator() -> ViewportController {
        viewportController
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
    var onHover: ((CGPoint?) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// Cross-section gizmo drag hooks. `beginGizmoDrag` returns true if a gizmo handle was grabbed at
    /// the point, in which case the drag is fed to `updateGizmoDrag` (view points) and `endGizmoDrag`
    /// is called at the end — taking precedence over camera control.
    var beginGizmoDrag: ((CGPoint) -> Bool)? = nil
    var updateGizmoDrag: ((CGPoint) -> Void)? = nil
    var endGizmoDrag: (() -> Void)? = nil
    var mouseInteractionActive: AnyPublisher<Bool, Never> { mouseInteractionActiveSubject.eraseToAnyPublisher() }
    var mouseRotationPivot: AnyPublisher<SCNVector3?, Never> { mouseRotationPivotSubject.eraseToAnyPublisher() }
    var showContextMenu: AnyPublisher<NSEvent, Never> { contextMenuSubject.eraseToAnyPublisher() }
    weak var viewportController: ViewportController?

    private let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    private let contextMenuSubject = PassthroughSubject<NSEvent, Never>()
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
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

    override func layout() {
        super.layout()
        overlaySKScene?.size = bounds.size
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area

        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
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
        // Any click (including the start of a camera drag) focuses this viewport.
        viewportController?.requestFocus()

        let localPoint = convert(event.locationInWindow, from: nil)

        // A left-press on a cross-section gizmo handle starts a manipulation, ahead of camera control.
        if event.type == .leftMouseDown, beginGizmoDrag?(localPoint) == true {
            // Disable camera control for the whole drag, or SCNView also rotates the view from it.
            let wasCameraControl = allowsCameraControl
            allowsCameraControl = false
            mouseInteractionActiveSubject.send(true)
            NSCursor.hide()
            _ = MouseTracker.track(with: event) { [weak self] location in
                guard let self else { return }
                updateGizmoDrag?(convert(location, from: nil))
            }
            NSCursor.unhide()
            endGizmoDrag?()
            // MouseTracker reads raw deltas and leaves the drag events in the queue; flush them so
            // they don't reach the camera and jump the view once control is restored.
            while NSApp.nextEvent(matching: .leftMouseDragged, until: .distantPast, inMode: .default, dequeue: true) != nil {}
            mouseInteractionActiveSubject.send(false)
            allowsCameraControl = wasCameraControl
            return
        }

        guard let viewportController, allowsCameraControl else { return }

        super.mouseDown(with: event)

        if let result = viewportController.nearestVisibleHit(at: localPoint, in: viewportController.modelInstance.root) {
            defaultCameraController.target = result.worldCoordinates
        } else {
            defaultCameraController.target = xyPlanePoint(forViewPoint: localPoint)
        }

        mouseInteractionActiveSubject.send(true)

        var didMove = false
        let endEvent = MouseTracker.track(with: event) { location in
            if !didMove {
                didMove = true
                // Defer the rotation pivot indicator and cursor hiding until an actual
                // drag begins, so a plain click doesn't flash the pivot dot.
                NSCursor.hide()
                if NSEvent.modifierFlags.intersection([.shift, .option]) == [] {
                    mouseRotationPivotSubject.send(defaultCameraController.target)
                }
            }

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

        if didMove {
            NSCursor.unhide()
        }
        super.mouseUp(with: endEvent)

        mouseRotationPivotSubject.send(nil)
        mouseInteractionActiveSubject.send(false)

        if !didMove {
            switch endEvent.type {
            case .rightMouseUp: contextMenuSubject.send(endEvent)
            case .leftMouseUp: onClick?(localPoint)
            default: break
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private let snapshotScale = 2.0

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
