import Foundation
import SwiftUI
import Combine
import SceneKit

public struct CoordinateSystemIndicator: View {
    let stream: AnyPublisher<OrientationIndicatorValues, Never>
    @State private var axes: OrientationIndicatorValues = .init(x: .zero, y: .zero, z: .zero)

    public init(stream: AnyPublisher<OrientationIndicatorValues, Never>) {
        self.stream = stream
    }

    private let width = 120.0
    private let radius = 50.0
    private let textRadius = 60.0

    public var body: some View {
        ZStack {
            Axis(value: axes.x, color: .red, label: "X", width: width, radius: radius, textRadius: textRadius)
            Axis(value: axes.y, color: .green, label: "Y", width: width, radius: radius, textRadius: textRadius)
            Axis(value: axes.z, color: .blue, label: "Z", width: width, radius: radius, textRadius: textRadius)
        }
        .shadow(color: .black, radius: 2, x: 0, y: 0)
        .frame(width: width, height: width)
        .onReceive(stream.receive(on: DispatchQueue.main)) { axes = $0 }
    }

    private struct Axis: View {
        let value: CGPoint
        let color: Color
        let label: String

        let width: CGFloat
        let radius: CGFloat
        let textRadius: CGFloat

        var body: some View {
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: value.x * radius, y: value.y * -radius))
            }
            .stroke(color)
            .offset(x: width / 2, y: width / 2)

            Text(label)
                .offset(x: value.x * textRadius, y: value.y * -textRadius)
                .font(.system(size: 10))
        }
    }
}

public struct OrientationIndicatorValues {
    public let x: CGPoint
    public let y: CGPoint
    public let z: CGPoint

    public init(x: CGPoint, y: CGPoint, z: CGPoint) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(x: SCNVector3, y: SCNVector3, z: SCNVector3) {
        self.x = CGPoint(x: x.x, y: x.y)
        self.y = CGPoint(x: y.x, y: y.y)
        self.z = CGPoint(x: z.x, y: z.y)
    }
}
