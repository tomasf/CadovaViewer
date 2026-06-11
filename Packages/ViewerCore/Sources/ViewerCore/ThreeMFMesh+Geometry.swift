import Foundation
import ThreeMF
import SceneKit
import AppKit
import simd

extension Mesh {
    public var statistics: ModelData.Statistics {
        .init(vertexCount: vertices.count, triangleCount: triangles.count)
    }

    public func edgeGeometries() -> (sharp: SCNGeometry, smooth: SCNGeometry) {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black

        let positions: [SCNVector3] = vertices.map(\.scnVector3)
        let vertexSource = SCNGeometrySource(vertices: positions)
        let (sharpEdgesElement, smoothEdgesElement) = extractEdgeSegments()

        let sharpGeometry = SCNGeometry(sources: [vertexSource], elements: [sharpEdgesElement])
        sharpGeometry.materials = [material]

        let smoothGeometry = SCNGeometry(sources: [vertexSource], elements: [smoothEdgesElement])
        smoothGeometry.materials = [material]

        return (sharpGeometry, smoothGeometry)
    }

    private func extractEdgeSegments() -> (sharp: SCNGeometryElement, smooth: SCNGeometryElement) {
        struct Edge: Hashable {
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
        var featureEdges: [Edge] = []
        var smoothEdges: [Edge] = []

        for (edge, faces) in edgeToTriangles {
            if faces.count == 1 {
                smoothEdges.append(edge)
                
            } else if faces.count == 2 {
                let n1 = triangleNormals[faces[0]]
                let n2 = triangleNormals[faces[1]]
                let dot = simd_dot(n1, n2)
                if dot < angleThreshold {
                    featureEdges.append(edge)
                } else {
                    smoothEdges.append(edge)
                }
            }
        }

        return (
            sharp: SCNGeometryElement(indices: featureEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }, primitiveType: .line),
            smooth: SCNGeometryElement(indices: smoothEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }, primitiveType: .line)
        )
    }

    /// Crease-aware smooth normals, one per triangle corner, indexed by `triangleIndex * 3 + corner`.
    ///
    /// Face normals are averaged per shared vertex, but only across edges whose dihedral angle is
    /// within `creaseAngleDegrees` — the same threshold used to classify sharp/feature edges — so
    /// genuine sharp edges keep hard, faceted shading while curved surfaces shade smoothly. The
    /// shading creases therefore coincide with the drawn sharp edges. Degenerate (zero-area)
    /// triangles never contribute a NaN normal; corners always receive a valid, normalized normal.
    public func smoothCornerNormals(creaseAngleDegrees: Double = 30) -> [SCNVector3] {
        struct Edge: Hashable {
            let v1: Int
            let v2: Int
            init(_ a: Int, _ b: Int) {
                if a < b { v1 = a; v2 = b } else { v1 = b; v2 = a }
            }
        }

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

        var edgeToTriangles: [Edge: [Int]] = [:]
        edgeToTriangles.reserveCapacity(cornerCount)
        for (faceIndex, t) in triangles.enumerated() {
            edgeToTriangles[Edge(t.v1, t.v2), default: []].append(faceIndex)
            edgeToTriangles[Edge(t.v2, t.v3), default: []].append(faceIndex)
            edgeToTriangles[Edge(t.v3, t.v1), default: []].append(faceIndex)
        }

        // Union-find over corners. Two corners are merged when they sit on the same mesh-vertex
        // and the edge connecting their triangles is smooth (within the crease threshold).
        var parent = Array(0..<cornerCount)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { parent[root] = parent[parent[root]]; root = parent[root] }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let cosThreshold = cos(creaseAngleDegrees * .pi / 180.0)
        for (edge, faces) in edgeToTriangles where faces.count == 2 {
            let f1 = faces[0], f2 = faces[1]
            guard faceValid[f1], faceValid[f2] else { continue }
            guard simd_dot(faceNormals[f1], faceNormals[f2]) >= cosThreshold else { continue }
            // Merge the corners at both endpoints of this shared, smooth edge.
            union(f1 * 3 + cornerIndex(of: edge.v1, in: triangles[f1]),
                  f2 * 3 + cornerIndex(of: edge.v1, in: triangles[f2]))
            union(f1 * 3 + cornerIndex(of: edge.v2, in: triangles[f1]),
                  f2 * 3 + cornerIndex(of: edge.v2, in: triangles[f2]))
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

        // Accumulate angle-weighted face normals into each smoothing group (keyed by its root).
        var groupNormals = [SIMD3<Double>](repeating: .zero, count: cornerCount)
        for f in 0..<triangleCount where faceValid[f] {
            for corner in 0..<3 {
                let weight = cornerAngle(face: f, corner: corner)
                groupNormals[find(f * 3 + corner)] += faceNormals[f] * weight
            }
        }

        var result = [SCNVector3](repeating: SCNVector3(0, 0, 1), count: cornerCount)
        for f in 0..<triangleCount {
            for corner in 0..<3 {
                let cornerID = f * 3 + corner
                var normal = groupNormals[find(cornerID)]
                let length = simd_length(normal)
                if length > 1e-12 {
                    normal /= length
                } else if faceValid[f] {
                    normal = faceNormals[f] // isolated/degenerate group → fall back to the face normal
                } else {
                    continue // keep the default; this corner belongs to a degenerate triangle
                }
                result[cornerID] = SCNVector3(normal.x, normal.y, normal.z)
            }
        }
        return result
    }
}
