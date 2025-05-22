import Foundation
import SwiftUI
import Combine

struct MeasurementListView: View {
    let stream: AnyPublisher<[Measurement], Never>
    @State private var measurements: [Measurement] = []
    let dismissAction: (Measurement) -> ()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(measurements) { measurement in
                    MeasurementView(measurement: measurement, color: measurement.color) { dismissAction(measurement) }
                }
            }
        }
        .colorScheme(.light)
        .onReceive(stream.receive(on: DispatchQueue.main)) { newMeasurements in
            withAnimation(measurements.count > newMeasurements.count ? .easeInOut(duration: 0.3) : nil) {
                measurements = newMeasurements
            }
        }
        .scrollClipDisabled()
    }
}

struct MeasurementView: View {
    let measurement: Measurement
    let color: Color
    let dismissAction: () -> ()

    private static var formatter = {
        let formatter = NumberFormatter()
        formatter.minimumIntegerDigits = 1
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    var body: some View {
        let distanceLabel = { (label: String, value: Double) in
            LabeledContent {
                (Text(Self.formatter.string(from: value as NSNumber) ?? "") + Text(" mm").foregroundStyle(.secondary))
                    .textSelection(.enabled)
            } label: {
                Text("\(label):").bold()
            }
        }

        let valueLabel = { (label: String, value: Double) in
            LabeledContent {
                (Text(Self.formatter.string(from: value as NSNumber) ?? "") + Text(" mm").foregroundStyle(.secondary))
                    .textSelection(.enabled)
            } label: {
                Text("\(label):").bold()
            }
        }

        let separator = Spacer().frame(height: 10)

        Form {
            valueLabel("Start X", measurement.fromPoint.x)
            valueLabel("Y", measurement.fromPoint.y)
            valueLabel("Z", measurement.fromPoint.z)

            if let endPoint = measurement.toPoint {
                separator
                valueLabel("End X", endPoint.x)
                valueLabel("Y", endPoint.y)
                valueLabel("Z", endPoint.z)
            }

            if let distanceMeasurement = measurement.distanceMeasurement {
                separator
                distanceLabel("Distance", distanceMeasurement.distance)
                distanceLabel("X Δ", distanceMeasurement.deltaX)
                distanceLabel("Y Δ", distanceMeasurement.deltaY)
                distanceLabel("Z Δ", distanceMeasurement.deltaZ)
            }
        }
        .padding()
        .padding(.top, 8)
        .overlay(alignment: .topLeading) {
            if measurement.toPoint != nil {
                Button {
                    dismissAction()
                } label: {
                    Image(systemName: "xmark")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white, lineWidth: 2)
                .stroke(color, lineWidth: 4)
                .fill(.thickMaterial)
        }
        .compositingGroup()
    }
}
