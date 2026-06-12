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
    var onCancel: (() -> Void)? = nil
    var mouseInteractionActive: AnyPublisher<Bool, Never> { mouseInteractionActiveSubject.eraseToAnyPublisher() }
    var mouseRotationPivot: AnyPublisher<SCNVector3?, Never> { mouseRotationPivotSubject.eraseToAnyPublisher() }
    var showContextMenu: AnyPublisher<NSEvent, Never> { contextMenuSubject.eraseToAnyPublisher() }
    weak var viewportController: ViewportController?

    private let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    private let contextMenuSubject = PassthroughSubject<NSEvent, Never>()

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
        guard let viewportController, allowsCameraControl else { return }

        super.mouseDown(with: event)
        let localPoint = convert(event.locationInWindow, from: nil)
        let edgeNodes = viewportController.edgeNodes

        if let result = hitTest(localPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber,
            .rootNode: viewportController.modelInstance.root
        ]).first(where: { !edgeNodes.contains($0.node) }) {
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
            // ⌘< / ⌘> cycle viewports — handled by the View-menu key equivalents, with this as a
            // belt-and-suspenders fallback matched on the typed character (so the physical < / >
            // key works even if the menu equivalent maps elsewhere on some layout).
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
               let viewModel = viewportController?.documentViewModel, viewModel.hasMultipleViewports,
               let chars = event.charactersIgnoringModifiers, chars == "<" || chars == ">" {
                viewModel.focusAdjacentViewport(forward: chars == ">")
            } else {
                super.keyDown(with: event)
            }
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

