import SwiftUI
import SceneKit
import AppKit

struct SidebarMeasurementRow: View {
    let measurement: Measurement
    let onDelete: () -> Void

    private var color: Color { Color(measurement.color) }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            coordinate("A", measurement.start)
            if let end = measurement.end {
                coordinate("B", end)
            }
            if let delta = measurement.delta {
                Divider()
                    .padding(.vertical, 5)
                coordinate("Δ", delta)
            }
            if let length = measurement.length {
                keyValuePair("Length", length)
            }
        }
        .font(.system(.callout))
        .monospacedDigit()
        .padding(14)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if measurement.phase != .coordinate {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .padding(6)
                }
                .contentShape(.interaction, Rectangle())
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func keyValuePair(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.formattedDistance)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func keyValuePairBox(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .center, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(value.formattedDistance)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func coordinate(_ label: String, _ point: SCNVector3) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.headline)
                .frame(width: 18, alignment: .leading)

            keyValuePairBox("X", point.x)
            keyValuePairBox("Y", point.y)
            keyValuePairBox("Z", point.z)
        }
    }
}

fileprivate extension Double {
    var formattedDistance: String {
        formatted(.number.precision(.integerAndFractionLength(integerLimits: 1..., fractionLimits: 3...3)))
    }
}
