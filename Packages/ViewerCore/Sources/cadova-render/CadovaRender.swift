import ArgumentParser
import Foundation
import AppKit
import ViewerCore

let viewPresetsByName: [String: ViewPreset] = [
    "isometric": .isometric,
    "front": .front,
    "back": .back,
    "left": .left,
    "right": .right,
    "top": .top,
    "bottom": .bottom,
]

@main
struct CadovaRender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cadova-render",
        abstract: "Renders a 3MF model file to an image, for documentation screenshots or other scripted use."
    )

    @Argument(help: "Path to the input .3mf file.")
    var input: String

    @Argument(help: "Path to the output image file (.png, .jpg, or .jpeg).")
    var output: String

    @Option(help: "Image width in pixels.")
    var width: Int = 1024

    @Option(help: "Image height in pixels.")
    var height: Int = 1024

    @Option(help: "View preset: \(viewPresetsByName.keys.sorted().joined(separator: ", ")).")
    var view: String = "isometric"

    @Option(help: "Camera projection: perspective or orthographic.")
    var projection: String = "perspective"

    @Option(help: "Which edges to draw: none, sharp, or all.")
    var edges: String = "sharp"

    @Option(help: "Headroom around the model as a multiple of the tightest fit (1.0 = no margin, edge-to-edge).")
    var margin: Double = 1.05

    @Flag(help: "Render with a transparent background instead of a solid color.")
    var transparent = false

    @Flag(help: "Show the reference grid.")
    var grid = false

    @Option(help: "Background color as a hex RGB value (e.g. FFFFFF), used when not transparent. Defaults to white.")
    var backgroundColor: String?

    @Flag(help: "Crop the output to the bounding box of the rendered content, trimming background pixels.")
    var trim = false

    @Option(help: "Padding in pixels to leave around the content when --trim is used.")
    var trimPadding: Int = 0

    func validate() throws {
        guard width > 0, height > 0 else {
            throw ValidationError("--width and --height must be positive.")
        }
        guard viewPresetsByName[view.lowercased()] != nil else {
            throw ValidationError("Unknown --view '\(view)'. Valid values: \(viewPresetsByName.keys.sorted().joined(separator: ", ")).")
        }
        guard ["perspective", "orthographic"].contains(projection.lowercased()) else {
            throw ValidationError("Unknown --projection '\(projection)'. Valid values: perspective, orthographic.")
        }
        guard EdgeVisibility(rawValue: edges.lowercased()) != nil else {
            throw ValidationError("Unknown --edges '\(edges)'. Valid values: none, sharp, all.")
        }
        guard margin > 0 else {
            throw ValidationError("--margin must be positive.")
        }
        guard trimPadding >= 0 else {
            throw ValidationError("--trim-padding must not be negative.")
        }
        let outputExtension = (output as NSString).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(outputExtension) else {
            throw ValidationError("Output file must end in .png, .jpg, or .jpeg.")
        }
        if transparent, outputExtension != "png" {
            throw ValidationError("--transparent requires a .png output file (JPEG doesn't support transparency).")
        }
        if let backgroundColor, NSColor(cadovaRenderHex: backgroundColor) == nil {
            throw ValidationError("Invalid --background-color '\(backgroundColor)'. Use a hex RGB value, e.g. FFFFFF.")
        }
    }

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        let preset = viewPresetsByName[view.lowercased()]!
        let cameraProjection: CameraProjection = projection.lowercased() == "orthographic" ? .orthographic : .perspective
        let resolvedEdgeVisibility = EdgeVisibility(rawValue: edges.lowercased())!
        let resolvedBackgroundColor = backgroundColor.flatMap { NSColor(cadovaRenderHex: $0) } ?? .white

        let modelData = try await ModelData(url: inputURL, includeEdges: resolvedEdgeVisibility != .none)
        let image = try ModelRenderer.render(
            modelData: modelData,
            preset: preset,
            size: CGSize(width: width, height: height),
            projection: cameraProjection,
            transparent: transparent,
            backgroundColor: resolvedBackgroundColor,
            showGrid: grid,
            edgeVisibility: resolvedEdgeVisibility,
            margin: margin
        )

        let outputImage = trim
            ? ImageTrimming.trim(image, backgroundColor: transparent ? nil : resolvedBackgroundColor, padding: trimPadding)
            : image
        try ImageWriter.write(outputImage, to: outputURL)
    }
}
