import Testing
import Foundation
import ThreeMF
@testable import ViewerCore

struct ThreeMFItemFilterTests {
    /// A minimal valid triangle mesh — enough for the loader to resolve an object.
    private func triangleMesh() -> Mesh {
        Mesh(
            vertices: [.init(x: 0, y: 0, z: 0), .init(x: 1, y: 0, z: 0), .init(x: 0, y: 1, z: 0)],
            triangles: [.init(v1: 0, v2: 1, v3: 2, propertyIndex: nil)]
        )
    }

    /// Builds a 3MF package with `itemCount` build items (each referencing its own mesh object, with a
    /// distinct part number) plus one auxiliary file, and writes it to a temporary `.3mf` file.
    /// Returns the source URL and the in-package path of the auxiliary file.
    private func makeSourcePackage(itemCount: Int) throws -> (sourceURL: URL, auxiliaryPath: URL) {
        let objects = (1...itemCount).map { Object(id: $0, content: .mesh(triangleMesh())) }
        let items = (1...itemCount).map { Item(objectID: $0, partNumber: "part-\($0)") }
        let model = Model(resources: objects, buildItems: items)

        let writer = PackageWriter()
        writer.model = model
        let auxiliaryPath = URL(string: "Metadata/extra.txt")!
        try writer.addFile(at: auxiliaryPath, contentType: "text/plain", relationshipType: nil, data: Data("keep me".utf8))
        let data = try writer.finalize()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.3mf")
        try data.write(to: sourceURL)
        return (sourceURL, auxiliaryPath)
    }

    @Test func `keeps only the build items at the requested indices`() async throws {
        let (sourceURL, _) = try makeSourcePackage(itemCount: 3)
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("out.3mf")

        try ThreeMFItemFilter.write(from: sourceURL, keepingItemIndices: IndexSet([0, 2]), to: destinationURL)

        let loaded = try await ModelLoader(url: destinationURL).load()
        #expect(loaded.items.count == 2)
        #expect(loaded.items.map(\.item.partNumber) == ["part-1", "part-3"])
    }

    @Test func `keeping a single index leaves exactly that item`() async throws {
        let (sourceURL, _) = try makeSourcePackage(itemCount: 3)
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("single.3mf")

        try ThreeMFItemFilter.write(from: sourceURL, keepingItemIndices: IndexSet(integer: 1), to: destinationURL)

        let loaded = try await ModelLoader(url: destinationURL).load()
        #expect(loaded.items.map(\.item.partNumber) == ["part-2"])
    }

    @Test func `preserves other archive entries verbatim`() async throws {
        let (sourceURL, auxiliaryPath) = try makeSourcePackage(itemCount: 2)
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("aux.3mf")

        try ThreeMFItemFilter.write(from: sourceURL, keepingItemIndices: IndexSet(integer: 0), to: destinationURL)

        let reader = try PackageReader(url: destinationURL)
        let auxiliaryData = try reader.readFile(at: auxiliaryPath)
        #expect(auxiliaryData == Data("keep me".utf8))
    }
}
