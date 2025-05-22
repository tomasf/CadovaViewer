import Foundation
import SwiftUI
import Combine

struct CoordinateSystemIndicator: View {
    let stream: AnyPublisher<OrientationIndicatorValues, Never>
    @State private var axes: OrientationIndicatorValues = .init(x: .zero, y: .zero, z: .zero)

    private let width = 120.0
    private let radius = 50.0
    private let textRadius = 60.0

    var body: some View {
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
