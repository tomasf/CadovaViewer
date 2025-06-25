import Foundation
import SpriteKit
import SceneKit
import Combine

final class OverlayScene: SKScene {
    private weak var sceneKitRenderer: SCNSceneRenderer!
    private weak var viewportController: ViewportController?

    private let transientNodeContainer = SKNode()

    private let pivotPointIndicator = SKShapeNode(circleOfRadius: 4)
    var pivotPointLocation = SCNVector3(0, 0, 0)
    var pivotPointVisibility = false {
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
    var delayedPivotPointHide: Task<Void, Error>?

    private var cancellables: Set<AnyCancellable> = []
    private var measurements: [Measurement] = []

    init(viewportController: ViewportController, renderer: SCNSceneRenderer) {
        self.viewportController = viewportController
        sceneKitRenderer = renderer
        super.init(size: .zero)
        isUserInteractionEnabled = false

        addChild(transientNodeContainer)
        addChild(pivotPointIndicator)

        pivotPointIndicator.fillColor = .red.withAlphaComponent(1)
        pivotPointIndicator.strokeColor = .black.withAlphaComponent(0.5)
        pivotPointIndicator.alpha = 0
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func update(_ currentTime: TimeInterval) {
        transientNodeContainer.removeAllChildren()

        guard let sceneKitRenderer else { return }

        let projectedPivot = sceneKitRenderer.projectPoint(pivotPointLocation)
        pivotPointIndicator.position = CGPoint(x: projectedPivot.x, y: projectedPivot.y)
    }
}
