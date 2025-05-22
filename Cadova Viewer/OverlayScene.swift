import Foundation
import SpriteKit
import SceneKit
import Combine

final class OverlayScene: SKScene {
    private weak var sceneKitRenderer: SCNSceneRenderer?
    private weak var viewportController: ViewportController?

    private let transientNodeContainer = SKNode()
    private let pivotPointIndicator = SKShapeNode(circleOfRadius: 8)

    private var cancellables: Set<AnyCancellable> = []
    private var measurements: [Measurement] = []

    init(viewportController: ViewportController, renderer: SCNSceneRenderer) {
        self.viewportController = viewportController
        sceneKitRenderer = renderer
        super.init(size: .zero)
        isUserInteractionEnabled = false

        addChild(transientNodeContainer)
        addChild(pivotPointIndicator)

        pivotPointIndicator.fillColor = .red
        pivotPointIndicator.strokeColor = .black
        pivotPointIndicator.alpha = 0

        viewportController.measurements.sink { [weak self] in self?.measurements = $0 }.store(in: &cancellables)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func update(_ currentTime: TimeInterval) {
        transientNodeContainer.removeAllChildren()

        guard let viewportController, let sceneKitRenderer else { return }

        let projectedPivot = sceneKitRenderer.projectPoint(viewportController.pivotPoint.location)
        pivotPointIndicator.position = CGPoint(x: projectedPivot.x, y: projectedPivot.y)

        let alpha = viewportController.pivotPoint.visible ? 1.0 : 0.0
        if pivotPointIndicator.alpha != alpha {
            pivotPointIndicator.run(.fadeAlpha(to: alpha, duration: 0.2))
        }

        guard viewportController.isAnimatingView == false else { return }

        for measurement in measurements {
            var flatPoints = measurement.points.map {
                let projected = sceneKitRenderer.projectPoint($0)
                return CGPoint(x: projected.x, y: projected.y)
            }

            if measurement.points.count > 1 {
                let line = flatPoints.withUnsafeMutableBufferPointer { bufferPointer in
                    SKShapeNode(points: bufferPointer.baseAddress!, count: measurement.points.count)
                }

                line.strokeColor = .white
                line.lineWidth = 1
                transientNodeContainer.addChild(line)
            }

            for p in flatPoints {
                let circle = SKShapeNode(circleOfRadius: 5)
                circle.fillColor = .init(measurement.color)
                circle.strokeColor = .black
                circle.position = p
                transientNodeContainer.addChild(circle)
            }
        }

    }
}
