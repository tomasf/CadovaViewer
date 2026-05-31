import SwiftUI
import SceneKit
import AppKit

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
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        if NSEvent.modifierFlags.contains(.option) {
                                            controller.deleteAll()
                                        } else {
                                            controller.delete(measurement.id)
                                        }
                                    }
                                }
                                .id(measurement.id)
                                .transition(.opacity)
                                .onHover { hovering in
                                    if hovering {
                                        controller.highlightedID = measurement.id
                                    } else if controller.highlightedID == measurement.id {
                                        controller.highlightedID = nil
                                    }
                                }
                            }
                        }
                        // The inset lives inside the scroll content so the boxes keep a
                        // margin from the window edge without the ScrollView clipping them.
                        .padding()
                    }
                    // Content-sized (so empty space below doesn't capture clicks meant
                    // for the model) but allowed to grow to the full available height.
                    .frame(width: 272, alignment: .leading)
                    .frame(maxHeight: max(geometry.size.height - bottomClearance, 0), alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .onHover { controller.isPointerOverList = $0 }
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
        .padding(.trailing, 4)
        .frame(width: 240, alignment: .leading)
        .background(.ultraThinMaterial)
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

            keyValuePairBox("X", point.x)
            keyValuePairBox("Y", point.y)
            keyValuePairBox("Z", point.z)
        }
    }

    @ViewBuilder
    private func deltaRow(_ delta: SCNVector3) -> some View {
        HStack(alignment: .center, spacing: 0) {
            keyValuePairBox("ΔX", delta.x)
            keyValuePairBox("ΔY", delta.y)
            keyValuePairBox("ΔZ", delta.z)
        }
    }
}

fileprivate extension Double {
    var formattedDistance: String {
        formatted(.number.precision(.integerAndFractionLength(integerLimits: 1..., fractionLimits: 3...3)))
    }
}
