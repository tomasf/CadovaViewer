import Foundation
import ThreeMF
import SceneKit
import AppKit
import simd

extension Mesh {
    public var statistics: ModelData.Statistics {
        .init(vertexCount: vertices.count, triangleCount: triangles.count)
    }

    /// Statistics for this mesh once placed into the scene by `transform`, including its surface
    /// area and enclosed volume in the transformed coordinate space.
    public func statistics(transform: simd_double4x4) -> ModelData.Statistics {
        let (area, volume) = areaAndVolume(transform: transform)
        return .init(vertexCount: vertices.count, triangleCount: triangles.count, surfaceArea: area, volume: volume)
    }

    /// Surface area and (absolute) enclosed volume of this mesh after applying `transform`.
    ///
    /// Volume is the signed-tetrahedron sum, meaningful only for a watertight mesh; its absolute
    /// value is returned so a mirrored (negative-determinant) transform still reports a positive
    /// volume. Area is the sum of the transformed triangle areas. Both are in the units of the
    /// transformed space — pass a transform that maps mesh coordinates to millimetres for mm²/mm³.
    public func areaAndVolume(transform: simd_double4x4) -> (area: Double, volume: Double) {
        func point(_ index: Int) -> SIMD3<Double> {
            let v = transform * SIMD4<Double>(vertices[index].simd, 1)
            return SIMD3(v.x, v.y, v.z)
        }

        var area = 0.0
        var signedVolume = 0.0
        for t in triangles {
            let a = point(t.v1)
            let b = point(t.v2)
            let c = point(t.v3)
            area += 0.5 * simd_length(simd_cross(b - a, c - a))
            signedVolume += simd_dot(a, simd_cross(b, c)) / 6.0
        }
        return (area, abs(signedVolume))
    }

    /// Builds this mesh's sharp and smooth edge lines, classifying each edge as needing a light or
    /// dark line colour by the triangles that border it — `triangleColors[i]` is triangle `i`'s own
    /// explicit colour (see `ThreeMF.Model.explicitTriangleColors(for:)`), or `nil` where it has none
    /// and would rely on the containing part's inherited colour, which isn't knowable here.
    public func edgeGeometries(triangleColors: [SIMD4<Float>?]) -> (sharp: EdgeLines, smooth: EdgeLines) {
        let positions: [SCNVector3] = vertices.map(\.scnVector3)
        let (sharpEdges, smoothEdges) = extractEdgeSegments()

        func edgeLines(_ edges: [(edge: Edge, faces: [Int])]) -> EdgeLines {
            var linePositions: [SCNVector3] = []
            linePositions.reserveCapacity(edges.count * 2)
            var needsLightColor: [Bool?] = []
            needsLightColor.reserveCapacity(edges.count)

            for (edge, faces) in edges {
                linePositions.append(positions[edge.v1])
                linePositions.append(positions[edge.v2])

                // Only commit to a known verdict when every bordering face has an explicit colour
                // of its own; a face relying on the part's inherited colour makes the edge's true
                // colour unknowable from the mesh alone, so it's left for the part-level fallback.
                let neighboringColors = faces.compactMap { triangleColors[$0] }
                if !neighboringColors.isEmpty && neighboringColors.count == faces.count {
                    needsLightColor.append(neighboringColors.contains { isDarkColor($0) })
                } else {
                    needsLightColor.append(nil)
                }
            }

            return EdgeLines(positions: linePositions, needsLightColor: needsLightColor)
        }

        return (edgeLines(sharpEdges), edgeLines(smoothEdges))
    }

    fileprivate struct Edge: Hashable {
        let v1: Int
        let v2: Int

        init(_ a: Int, _ b: Int) {
            if a < b {
                v1 = a
                v2 = b
            } else {
                v1 = b
                v2 = a
            }
        }
    }

    private func extractEdgeSegments() -> (sharp: [(edge: Edge, faces: [Int])], smooth: [(edge: Edge, faces: [Int])]) {
        var edgeToTriangles: [Edge: [Int]] = [:]
        for (faceIndex, triangle) in triangles.enumerated() {
            let edges = [
                Edge(triangle.v1, triangle.v2),
                Edge(triangle.v2, triangle.v3),
                Edge(triangle.v3, triangle.v1)
            ]
            for edge in edges {
                edgeToTriangles[edge, default: []].append(faceIndex)
            }
        }

        func normal(of triangle: Triangle) -> SIMD3<Double> {
            let a = vertices[triangle.v1].simd
            let b = vertices[triangle.v2].simd
            let c = vertices[triangle.v3].simd
            let ab = b - a
            let ac = c - a
            return simd_normalize(simd_cross(ab, ac))
        }

        let triangleNormals = triangles.map { normal(of: $0) }

        let maxSmoothAngleDegrees = 30.0
        let angleThreshold = cos(maxSmoothAngleDegrees * .pi / 180.0)
        var featureEdges: [(edge: Edge, faces: [Int])] = []
        var smoothEdges: [(edge: Edge, faces: [Int])] = []

        for (edge, faces) in edgeToTriangles {
            if faces.count == 1 {
                smoothEdges.append((edge, faces))

            } else if faces.count == 2 {
                let n1 = triangleNormals[faces[0]]
                let n2 = triangleNormals[faces[1]]
                let dot = simd_dot(n1, n2)
                if dot < angleThreshold {
                    featureEdges.append((edge, faces))
                } else {
                    smoothEdges.append((edge, faces))
                }
            }
        }

        return (featureEdges, smoothEdges)
    }

    /// Crease-aware smooth normals, one per triangle corner, indexed by `triangleIndex * 3 + corner`.
    ///
    /// Each corner averages the normals of the faces around its vertex, but only those whose
    /// normal lies within `creaseAngleDegrees` of the corner's *own* face normal — the same
    /// threshold used to classify sharp/feature edges. The test being face-relative (rather than
    /// transitive smoothing groups) means a flat region can't be tilted by an adjacent curved
    /// surface: every corner of a coplanar region averages the same coplanar set and shades
    /// perfectly flat, while curved surfaces still shade smoothly, and no corner can ever deviate
    /// more than the crease angle from its face. Degenerate (zero-area) triangles never
    /// contribute a NaN normal; corners always receive a valid, normalized normal.
    public func smoothCornerNormals(creaseAngleDegrees: Double = 30) -> [SCNVector3] {
        let triangleCount = triangles.count
        let cornerCount = triangleCount * 3

        // Per-face normals, flagging degenerate triangles so they're excluded from averaging.
        var faceNormals = [SIMD3<Double>](repeating: .zero, count: triangleCount)
        var faceValid = [Bool](repeating: false, count: triangleCount)
        for (i, t) in triangles.enumerated() {
            let a = vertices[t.v1].simd
            let b = vertices[t.v2].simd
            let c = vertices[t.v3].simd
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            if length > 1e-12 {
                faceNormals[i] = cross / length
                faceValid[i] = true
            }
        }

        // Local corner index (0/1/2) of a given mesh-vertex within a triangle.
        func cornerIndex(of vertex: Int, in t: Triangle) -> Int {
            if t.v1 == vertex { return 0 }
            if t.v2 == vertex { return 1 }
            return 2
        }

        // Faces around each mesh-vertex.
        var vertexFaces = [[Int32]](repeating: [], count: vertices.count)
        for (faceIndex, t) in triangles.enumerated() {
            vertexFaces[t.v1].append(Int32(faceIndex))
            vertexFaces[t.v2].append(Int32(faceIndex))
            vertexFaces[t.v3].append(Int32(faceIndex))
        }

        // Interior angle at a corner, used to weight each face's contribution (Thürmer–Wüthrich),
        // which gives better normals on irregular tessellations than unweighted or area weighting.
        func cornerAngle(face f: Int, corner: Int) -> Double {
            let t = triangles[f]
            let p = [vertices[t.v1].simd, vertices[t.v2].simd, vertices[t.v3].simd]
            let origin = p[corner]
            let u = p[(corner + 1) % 3] - origin
            let v = p[(corner + 2) % 3] - origin
            let lu = simd_length(u), lv = simd_length(v)
            guard lu > 1e-12, lv > 1e-12 else { return 0 }
            return acos(min(1, max(-1, simd_dot(u, v) / (lu * lv))))
        }

        // For each corner, blend the angle-weighted normals of the surrounding faces that lie
        // within the crease angle of the corner's own face. Contributions also taper smoothly
        // to zero as they approach the crease angle: a hard cutoff would let a feature bevel
        // just under the threshold (e.g. a 25° cone skirting a flat face) tilt the flat face's
        // edge normals by tens of degrees, which smears a shadow-like gradient across large
        // faces. With the taper, near-threshold neighbors contribute almost nothing, while the
        // small dihedrals of finely tessellated curved surfaces keep nearly full weight.
        let cosThreshold = cos(creaseAngleDegrees * .pi / 180.0)
        var result = [SCNVector3](repeating: SCNVector3(0, 0, 1), count: cornerCount)
        for f in 0..<triangleCount where faceValid[f] {
            let t = triangles[f]
            for (corner, vertex) in [(0, t.v1), (1, t.v2), (2, t.v3)] {
                var normal = SIMD3<Double>.zero
                for packedFace in vertexFaces[vertex] {
                    let g = Int(packedFace)
                    guard faceValid[g] else { continue }
                    let dot = simd_dot(faceNormals[g], faceNormals[f])
                    guard dot >= cosThreshold else { continue }
                    let angleDegrees = acos(min(1, dot)) * 180 / .pi
                    let closeness = max(0, min(1, 1 - angleDegrees / creaseAngleDegrees))
                    let taper = closeness * closeness * (3 - 2 * closeness)
                    let weight = cornerAngle(face: g, corner: cornerIndex(of: vertex, in: triangles[g])) * taper
                    normal += faceNormals[g] * weight
                }
                let length = simd_length(normal)
                let unit = length > 1e-12 ? normal / length : faceNormals[f]
                result[f * 3 + corner] = SCNVector3(unit.x, unit.y, unit.z)
            }
        }
        return result
    }
}

/// A mesh's edge lines (sharp or smooth), each classified as needing a light or dark colour by its
/// bordering faces — or left unresolved (`nil` in `needsLightColor`) where those faces rely on a
/// colour inherited from the part rather than one of their own. Positions are duplicated per edge
/// (not shared via indices into the mesh's vertex list) so each edge can carry its own colour
/// without bleeding into its neighbors, the same reasoning the main mesh geometry uses for
/// per-triangle vertex colours.
public struct EdgeLines {
    fileprivate let positions: [SCNVector3]
    fileprivate let needsLightColor: [Bool?]

    fileprivate static let darkColor = ThreeMF.Color(red: 0, green: 0, blue: 0).scnVector4
    fileprivate static let lightColor = ThreeMF.Color(red: 160, green: 160, blue: 160).scnVector4

    static let empty = EdgeLines(positions: [], needsLightColor: [])

    /// Builds the renderable line geometry, resolving any edge left unclassified by
    /// `edgeGeometries(triangleColors:)` (its bordering faces relied on an inherited colour) to
    /// `unknownNeedsLightColor` — the containing part's own dominant-colour darkness check, the
    /// best information available once the mesh alone can't say.
    public func geometry(unknownNeedsLightColor: Bool) -> SCNGeometry {
        guard !positions.isEmpty else {
            return SCNGeometry()
        }

        var colors: [SCNVector4] = []
        colors.reserveCapacity(positions.count)
        for needsLight in needsLightColor {
            let color = (needsLight ?? unknownNeedsLightColor) ? Self.lightColor : Self.darkColor
            colors.append(color)
            colors.append(color)
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let colorSource = SCNGeometrySource.colors(colors)
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(positions.count)), primitiveType: .line)

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        geometry.materials = [material]
        return geometry
    }
}

/// Whether `color` (linear RGBA) reads as dark enough that a black line drawn against it would
/// disappear. Relative luminance using Rec. 709 coefficients.
func isDarkColor(_ color: SIMD4<Float>) -> Bool {
    0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z < 0.05
}
