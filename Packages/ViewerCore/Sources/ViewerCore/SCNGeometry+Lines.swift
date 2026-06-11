import SceneKit
import AppKit

extension SCNGeometry {
    /// A line-primitive geometry connecting each pair of points, drawn unlit in `color`.
    public static func lines(_ segments: [(SCNVector3, SCNVector3)], color: NSColor) -> SCNGeometry {
        let element = SCNGeometryElement(indices: (0..<segments.count*2).map(Int32.init), primitiveType: .line)
        let points = segments.flatMap { [$0, $1] }
        let lineGeo = SCNGeometry(sources: [.init(vertices: points)], elements: [element])
        lineGeo.firstMaterial?.lightingModel = .constant
        lineGeo.firstMaterial?.diffuse.contents = color
        return lineGeo
    }
}
