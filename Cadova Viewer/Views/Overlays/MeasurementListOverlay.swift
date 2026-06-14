import SwiftUI
import SceneKit
import AppKit

struct MeasurementSidebarSection: View {
    @ObservedObject var controller: MeasurementController
    let height: CGFloat

    @State private var contentHeight: CGFloat = 0

    private var rows: [Measurement] {
        controller.measurements + (controller.hoverPreview.map { [$0] } ?? [])
    }

    var body: some View {
        if !rows.isEmpty, height > 1 {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { measurement in
                                SidebarMeasurementRow(measurement: measurement) {
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
                        .padding(8)
                        .readHeight($contentHeight)
                    }
                    .frame(height: height)
                    .onHover { controller.isPointerOverList = $0 }
                    .onDisappear { controller.isPointerOverList = false }
                    .onChange(of: rows.last?.id) { _, lastID in
                        scrollToBottom(proxy, lastID: lastID)
                    }
                    .onChange(of: rows.map(\.id)) { _, _ in
                        contentHeight = 0
                    }
                    .onChange(of: contentHeight) { _, _ in
                        scrollToBottom(proxy, lastID: rows.last?.id)
                    }
                }
            }
            .background(.thinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, lastID: Measurement.ID?) {
        if let lastID {
            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
        }
    }
}

private struct SidebarMeasurementRow: View {
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
                .frame(width: 28, alignment: .leading)

            keyValuePairBox("X", point.x)
            keyValuePairBox("Y", point.y)
            keyValuePairBox("Z", point.z)
        }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func readHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(HeightPreferenceKey.self) { height.wrappedValue = $0 }
    }
}

fileprivate extension Double {
    var formattedDistance: String {
        formatted(.number.precision(.integerAndFractionLength(integerLimits: 1..., fractionLimits: 3...3)))
    }
}
