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
            HStack(alignment: .top) {
                Text(measurement.end == nil && measurement.phase == .coordinate ? "Point" : "Length")
                    .font(.headline)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if measurement.phase == .coordinate {
                coordinate("", measurement.start)
            } else {
                coordinate("Start", measurement.start)
                if let end = measurement.end {
                    coordinate("End", end)
                } else {
                    Text("End  —")
                        .foregroundStyle(.secondary)
                }
                Divider()
                valueRow("Length", measurement.length)
                if let delta = measurement.delta {
                    deltaRow(delta)
                } else {
                    Text("Δ  —")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color, lineWidth: 2)
        }
    }

    @ViewBuilder
    private func coordinate(_ label: String, _ point: SCNVector3) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !label.isEmpty {
                Text(label).foregroundStyle(.secondary)
            }
            Text("X  \(Double(point.x).measurementFormatted)")
            Text("Y  \(Double(point.y).measurementFormatted)")
            Text("Z  \(Double(point.z).measurementFormatted)")
        }
    }

    @ViewBuilder
    private func valueRow(_ label: String, _ value: Double?) -> some View {
        Text("\(label)  \(value?.measurementFormatted ?? "—")")
    }

    @ViewBuilder
    private func deltaRow(_ delta: SCNVector3) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("ΔX \(Double(delta.x).measurementFormatted)")
            Text("ΔY \(Double(delta.y).measurementFormatted)")
            Text("ΔZ \(Double(delta.z).measurementFormatted)")
        }
    }
}
