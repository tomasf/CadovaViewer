import Foundation
import Zip
import Nodal

/// Produces a copy of a 3MF package that keeps only a chosen subset of its build `<item>` elements.
///
/// The copy is made at the archive level: every entry from the source is written out verbatim, except
/// the root model part, whose XML is edited to drop the unwanted `<item>` elements. Nothing else in the
/// package is touched — textures, thumbnails, additional `.model` files and relationships all survive.
/// This is deliberately *not* a `ThreeMF.Model` round-trip, which would re-serialise the whole model and
/// risk dropping anything the model type doesn't represent.
public enum ThreeMFItemFilter {
    public enum Error: Swift.Error {
        /// The package didn't contain a readable root model part.
        case rootModelNotFound
        /// The root model XML had no `<build>` element to filter.
        case noBuildElement
    }

    private enum Namespaces {
        static let core = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
        static let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        static let modelRelationshipType = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"
    }

    /// The conventional root-model path, used when the package relationships don't point us elsewhere.
    /// The 3MF writers in this ecosystem hardcode it too (Cura only ever reads this name).
    private static let defaultRootModelPath = "3D/3dmodel.model"
    private static let relationshipsPath = "_rels/.rels"

    /// Copies the 3MF at `sourceURL` to `destinationURL`, keeping only the build `<item>` elements whose
    /// document-order index is contained in `keptItemIndices`. All other archive entries are copied
    /// unchanged.
    ///
    /// - Parameters:
    ///   - sourceURL: The 3MF package to read.
    ///   - keptItemIndices: The zero-based, document-order indices of the build items to keep. These line
    ///     up with `ModelData.Part.itemIndex`.
    ///   - destinationURL: Where to write the filtered package. Any existing file is overwritten.
    public static func write(from sourceURL: URL, keepingItemIndices keptItemIndices: IndexSet, to destinationURL: URL) throws {
        let source = try ZipArchive(url: sourceURL, mode: .readOnly)
        defer { source.close() }

        let modelPath = (try? rootModelPath(in: source)) ?? defaultRootModelPath
        guard let modelData = try? source.fileContents(at: modelPath) else {
            throw Error.rootModelNotFound
        }

        let filteredModelData = try filteredModelXML(modelData, keepingItemIndices: keptItemIndices)

        let destination = try ZipArchive(url: destinationURL, mode: .overwrite)
        for entry in try source.entries where entry.kind == .file {
            let data = entry.path == modelPath ? filteredModelData : try source.fileContents(at: entry.path)
            try destination.addFile(at: entry.path, data: data)
        }
        try destination.finalize()
    }

    /// Resolves the root model's path within the package from the OPC relationships (`_rels/.rels`),
    /// normalised to an archive entry path (no leading slash).
    private static func rootModelPath(in archive: ZipArchive<URL>) throws -> String {
        let data = try archive.fileContents(at: relationshipsPath)
        let document = try Document(data: data)
        guard let root = document.documentElement else { throw Error.rootModelNotFound }

        for relationship in root[elements: "Relationship", uri: Namespaces.relationships] {
            guard relationship[attribute: "Type", namespaceName: nil] == Namespaces.modelRelationshipType,
                  let target = relationship[attribute: "Target", namespaceName: nil]
            else { continue }
            return normalizedEntryPath(target)
        }
        throw Error.rootModelNotFound
    }

    /// Parses the model XML, removes the `<item>` elements whose order index isn't kept, and re-serialises.
    private static func filteredModelXML(_ data: Data, keepingItemIndices keptItemIndices: IndexSet) throws -> Data {
        let document = try Document(data: data)
        guard let root = document.documentElement,
              let build = root[element: "build", uri: Namespaces.core]
        else { throw Error.noBuildElement }

        for (index, item) in build[elements: "item", uri: Namespaces.core].enumerated() where !keptItemIndices.contains(index) {
            build.removeChild(item)
        }
        return try document.xmlData()
    }

    private static func normalizedEntryPath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}
