import SwiftUI
import SceneKit
import AppKit

struct SidebarMeasurementRow: View {
    let measurement: Measurement
    let onDelete: () -> Void

    @Environment(\.appearsActive) private var appearsActive

    private var color: Color { ColorPalette.color(forIndex: measurement.colorIndex) }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            axisHeader
            coordinate("A", measurement.start)
            if let end = measurement.end {
                coordinate("B", end)
            }
            if let delta = measurement.delta {
                Divider()
                    .padding(.vertical, 3)
                coordinate("Δ", delta)
            }
            if let length = measurement.length {
                keyValuePair("Length", length)
            }
        }
        .font(.system(.callout))
        .monospacedDigit()
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if measurement.phase != .coordinate {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .frame(width: 26, height: 32, alignment: .center)
                }
                .contentShape(.interaction, Rectangle())
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Copy") {
                copyMeasurement()
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
            .disabled(measurement.phase == .coordinate)
        }
        .listRowBackground(rowBackground)
    }

    /// The material chip behind the row, with its colour-coded border. The border dims when the window
    /// is inactive (`appearsActive`) so it doesn't stay vivid while the window is in the background.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(appearsActive ? color : color.opacity(0.45), lineWidth: 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private func copyMeasurement() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(measurement.copyText, forType: .string)
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

    /// The X/Y/Z column headers, shown once above the coordinate rows. The leading spacer matches the
    /// A/B/Δ row-label width so the headers line up over their value columns.
    private var axisHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: 18)
            columnHeader("X")
            columnHeader("Y")
            columnHeader("Z")
        }
    }

    @ViewBuilder
    private func columnHeader(_ label: String) -> some View {
        Text(label)
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func valueBox(_ value: Double) -> some View {
        Text(value.formattedDistance)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func coordinate(_ label: String, _ point: SCNVector3) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.headline)
                .frame(width: 18, alignment: .leading)

            valueBox(point.x)
            valueBox(point.y)
            valueBox(point.z)
        }
    }
}

fileprivate extension Double {
    var formattedDistance: String {
        formatted(.number.precision(.integerAndFractionLength(integerLimits: 1..., fractionLimits: 3...3)))
    }

    var formattedMeasurementCopyValue: String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: self)) ?? "\(self)") + " mm"
    }
}

fileprivate extension CGFloat {
    var formattedMeasurementCopyValue: String {
        Double(self).formattedMeasurementCopyValue
    }
}

private extension Measurement {
    var copyText: String {
        var sections = [pointText(title: "Point A", point: start)]
        if let end {
            sections.append(pointText(title: "Point B", point: end))
        }
        if let delta {
            sections.append(pointText(title: "Delta", point: delta))
        }
        if let length {
            sections.append("Length: \(length.formattedMeasurementCopyValue)")
        }
        return sections.joined(separator: "\n\n")
    }

    func pointText(title: String, point: SCNVector3) -> String {
        """
        \(title)
        X: \(point.x.formattedMeasurementCopyValue)
        Y: \(point.y.formattedMeasurementCopyValue)
        Z: \(point.z.formattedMeasurementCopyValue)
        """
    }
}
