import Testing
import ThreeMF
import SceneKit
@testable import ViewerCore

struct EdgeAlphaTests {
    private static let opaque = ThreeMF.Color(red: 200, green: 50, blue: 50)
    private static let halfClear = ThreeMF.Color(red: 200, green: 50, blue: 50, alpha: 128)
    private static let clear = ThreeMF.Color(red: 0, green: 0, blue: 0, alpha: 0)

    /// A unit cube whose triangles all inherit their colour from the object, the way Cadova writes a
    /// single-coloured part, plus a colour group holding the three test colours.
    private static func cube() -> (ThreeMF.Model, ThreeMF.Mesh, ColorGroup) {
        let vertices = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ].map { ThreeMF.Mesh.Vertex(x: Double($0.0), y: Double($0.1), z: Double($0.2)) }
        let faces = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
        ]
        let triangles = faces.map { ThreeMF.Mesh.Triangle(v1: $0.0, v2: $0.1, v3: $0.2, propertyIndex: nil, propertyGroup: nil) }

        var colors = ColorGroup(id: 1)
        _ = colors.addColor(opaque)
        _ = colors.addColor(halfClear)
        _ = colors.addColor(clear)
        return (ThreeMF.Model(unit: .millimeter, resources: [colors]), ThreeMF.Mesh(vertices: vertices, triangles: triangles), colors)
    }

    /// The edge geometry a component inheriting colour `index` draws, and the mesh's geometry result.
    private static func edges(inheritingColor index: ResourceIndex) -> (lines: SCNGeometry, result: MeshGeometryResult) {
        let (model, mesh, colors) = cube()
        let inherited = PartialPropertyReference(groupID: colors.id, index: index)
        let result = model.geometry(for: mesh, inheritedProperty: inherited)
        let edgeLines = mesh.edgeGeometries(triangleColors: model.explicitTriangleColors(for: mesh))
        let lines = edgeLines.sharp.geometry(unknownNeedsLightColor: false, triangleAlphas: result.triangleAlphas)
        return (lines, result)
    }

    private static func vertexCount(of geometry: SCNGeometry) -> Int {
        geometry.sources(for: .vertex).first?.vectorCount ?? 0
    }

    private static func alphas(of geometry: SCNGeometry) -> Set<Float> {
        guard let source = geometry.sources(for: .color).first else { return [] }
        return source.data.withUnsafeBytes { bytes in
            Set((0..<source.vectorCount).map { vector in
                let offset = source.dataOffset + vector * source.dataStride + 3 * source.bytesPerComponent
                return source.bytesPerComponent == 4
                    ? bytes.load(fromByteOffset: offset, as: Float.self)
                    : Float(bytes.load(fromByteOffset: offset, as: Double.self))
            })
        }
    }

    @Test func `an opaque part draws every sharp edge fully opaque`() {
        let (lines, _) = Self.edges(inheritingColor: 0)
        // A cube has 12 sharp edges, two line vertices each.
        #expect(Self.vertexCount(of: lines) == 24)
        #expect(Self.alphas(of: lines) == [1])
    }

    @Test func `a translucent part fades its edges to match`() {
        let (lines, _) = Self.edges(inheritingColor: 1)
        #expect(Self.vertexCount(of: lines) == 24)
        let alphas = Self.alphas(of: lines)
        #expect(alphas.count == 1)
        #expect(Swift.abs((alphas.first ?? 0) - 128.0 / 255.0) < 0.001)
    }

    @Test func `a fully transparent part draws no edges and counts as absent`() {
        let (lines, result) = Self.edges(inheritingColor: 2)
        #expect(Self.vertexCount(of: lines) == 0)
        #expect(result.isInvisible)
    }

    @Test func `an edge between a clear and an opaque face stays fully visible`() {
        var (model, mesh, colors) = Self.cube()
        // Make the bottom face (the first two triangles) clear and leave the rest inheriting opaque.
        for index in 0..<2 {
            let t = mesh.triangles[index]
            mesh.triangles[index] = ThreeMF.Mesh.Triangle(v1: t.v1, v2: t.v2, v3: t.v3, propertyIndex: .uniform(2), propertyGroup: colors.id)
        }
        model = ThreeMF.Model(unit: .millimeter, resources: [colors])
        let result = model.geometry(for: mesh, inheritedProperty: PartialPropertyReference(groupID: colors.id, index: 0))
        let edgeLines = mesh.edgeGeometries(triangleColors: model.explicitTriangleColors(for: mesh))
        let lines = edgeLines.sharp.geometry(unknownNeedsLightColor: false, triangleAlphas: result.triangleAlphas)

        // Every sharp edge of a cube borders at least one side face, so all 12 still draw.
        #expect(Self.vertexCount(of: lines) == 24)
        #expect(Self.alphas(of: lines) == [1])
        #expect(!result.isInvisible)
    }

    @Test func `a pbr material always counts as opaque for edges`() {
        let pbr = PBRMaterial(diffuse: Self.clear, metallicness: 0, roughness: 1, name: nil)
        #expect(Material.pbr(pbr).edgeAlpha == 1)
        #expect(Swift.abs(Material.vertexColors(Self.clear, Self.halfClear, Self.clear).edgeAlpha - 128.0 / 255.0) < 0.001)
    }
}
