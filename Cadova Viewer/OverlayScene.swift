import Foundation
import SpriteKit
import SceneKit
import Combine

final class OverlayScene: SKScene {
    private weak var sceneKitRenderer: SCNSceneRenderer!
    private weak var viewportController: ViewportController?

    private let transientNodeContainer = SKNode()

    private let pivotPointIndicator = SKShapeNode(circleOfRadius: 6)
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

        pivotPointIndicator.fillColor = .red
        pivotPointIndicator.strokeColor = .black.withAlphaComponent(0.5)
        pivotPointIndicator.alpha = 0

        viewportController.measurements.sink { [weak self] in self?.measurements = $0 }.store(in: &cancellables)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func update(_ currentTime: TimeInterval) {
        transientNodeContainer.removeAllChildren()

        guard let viewportController, let sceneKitRenderer else { return }

        let projectedPivot = sceneKitRenderer.projectPoint(pivotPointLocation)
        pivotPointIndicator.position = CGPoint(x: projectedPivot.x, y: projectedPivot.y)

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
