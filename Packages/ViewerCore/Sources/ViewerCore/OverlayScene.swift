import Foundation
import SpriteKit
import SceneKit
import os

/// The SpriteKit overlay drawn on top of a scene view: the red pivot indicator shown while orbiting.
/// Shared by the app's viewports and the Quick Look preview.
public final class OverlayScene: SKScene {
    private weak var sceneKitRenderer: SCNSceneRenderer?

    private let pivotPointIndicator = SKShapeNode(circleOfRadius: 4)

    /// The world-space point the pivot indicator tracks. Written on the main thread (from the
    /// scene view's rotation-pivot stream) and read every frame by `update(_:)`, which SpriteKit
    /// drives on its own render thread — so it's guarded by a lock to avoid a torn read of the
    /// `SCNVector3` components.
    public var pivotPointLocation: SCNVector3 {
        get { _pivotPointLocation.withLock { $0 } }
        set { _pivotPointLocation.withLock { $0 = newValue } }
    }
    private let _pivotPointLocation = OSAllocatedUnfairLock<SCNVector3>(initialState: SCNVector3(0, 0, 0))
    public var pivotPointVisibility = false {
        didSet {
            guard pivotPointVisibility != oldValue else { return }

            delayedPivotPointHide?.cancel()
            pivotPointIndicator.removeAllActions()
            if pivotPointVisibility {
                pivotPointIndicator.run(.fadeAlpha(to: 1, duration: 0.1))
            } else {
                delayedPivotPointHide = Task {
                    try await Task.sleep(for: .milliseconds(300))
                    guard !pivotPointVisibility else { return }
                    await pivotPointIndicator.run(.fadeAlpha(to: 0, duration: 0.3))
                }
            }
        }
    }
    private var delayedPivotPointHide: Task<Void, Error>?

    public init(renderer: SCNSceneRenderer) {
        sceneKitRenderer = renderer
        super.init(size: .zero)
        isUserInteractionEnabled = false

        addChild(pivotPointIndicator)

        pivotPointIndicator.fillColor = .red
        pivotPointIndicator.strokeColor = .black.withAlphaComponent(0.5)
        pivotPointIndicator.alpha = 0
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func update(_ currentTime: TimeInterval) {
        guard let sceneKitRenderer else { return }

        let projectedPivot = sceneKitRenderer.projectPoint(pivotPointLocation)
        pivotPointIndicator.position = CGPoint(x: projectedPivot.x, y: projectedPivot.y)
    }
}
