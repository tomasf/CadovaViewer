import SwiftUI
import SceneKit

struct MeasurementListOverlay: View {
    @ObservedObject var controller: MeasurementController

    private var rows: [Measurement] {
        controller.measurements + (controller.hoverPreview.map { [$0] } ?? [])
    }

    /// Vertical space left clear at the bottom for the parts button overlay.
    private let bottomClearance: CGFloat = 64

    var body: some View {
        if controller.interactionMode == .measure || !controller.measurements.isEmpty {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { measurement in
                                MeasurementRow(measurement: measurement) {
                                    controller.delete(measurement.id)
                                }
                                .id(measurement.id)
                            }
                        }
                        // The inset lives inside the scroll content so the boxes keep a
                        // margin from the window edge without the ScrollView clipping them.
                        .padding()
                    }
                    // Content-sized (so empty space below doesn't capture clicks meant
                    // for the model) but allowed to grow to the full available height.
                    .frame(maxWidth: 272, alignment: .leading)
                    .frame(maxHeight: max(geometry.size.height - bottomClearance, 0), alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: rows.last?.id) { _, lastID in
                        if let lastID {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct MeasurementRow: View {
    let measurement: Measurement
    let onDelete: () -> Void

    private var color: Color { Color(measurement.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if measurement.phase == .coordinate {
                coordinate("", measurement.start)
            } else {
                coordinate("Start", measurement.start)
                if let end = measurement.end {
                    Divider()
                    coordinate("End", end)
                }
                Divider()
                keyValuePair("Length", measurement.length ?? 0)
                if let delta = measurement.delta {
                    deltaRow(delta)
                } else {
                    Text("Δ  —")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(.callout))
        .monospacedDigit()
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if measurement.phase != .coordinate {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.bold))
                        .padding()
                }
                .contentShape(.interaction, Rectangle())
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func keyValuePair(_ label: String, _ value: Double) -> some View {
        let string = value.formatted(.number.precision(.integerAndFractionLength(integerLimits: 1..., fractionLimits: 3...3)))
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Text(string + " mm")
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func coordinate(_ label: String, _ point: SCNVector3) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label).foregroundStyle(.secondary)
            }
            keyValuePair("X", point.x)
            keyValuePair("Y", point.y)
            keyValuePair("Z", point.z)
        }
    }

    @ViewBuilder
    private func deltaRow(_ delta: SCNVector3) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            keyValuePair("ΔX", delta.x)
            keyValuePair("ΔY", delta.y)
            keyValuePair("ΔZ", delta.z)
        }
    }
}
