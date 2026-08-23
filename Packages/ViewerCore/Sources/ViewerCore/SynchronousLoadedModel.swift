import Foundation
import ThreeMF

// This intentionally narrow duplication mirrors `ThreeMF.ModelLoader.load()` but keeps the whole
// flattening step synchronous. The public ThreeMF loader currently uses Swift task groups; when
// Cadova Viewer then builds large SceneKit-backed `ModelData` values from that async result, launch
// can abort in `swift_task_dealloc` while tearing down the coroutine frame. Keeping the file-load
// flattening outside Swift concurrency avoids that runtime/compiler issue without changing ThreeMF's
// public API for other clients. Delete this when ThreeMF exposes a synchronous/non-task-group loader.
struct SynchronousLoadedModel {
    let rootModel: Model
    let models: [Model]
    let meshes: [LoadedMesh]
    let items: [LoadedItem]

    init(url: URL) throws {
        func makeReader() throws -> PackageReader<URL> {
            try PackageReader(url: url)
        }

        let rootModel = try makeReader().model()

        let additionalModelPaths = Set(rootModel.build.items.compactMap(\.path))
            .union(rootModel.resources.resources.flatMap { resource -> [URL] in
                guard let object = resource as? Object,
                      case .components(let components) = object.content
                else { return [] }
                return components.compactMap(\.path)
            })

        var additionalModels: [(URL, Model)] = []
        additionalModels.reserveCapacity(additionalModelPaths.count)
        for path in additionalModelPaths {
            additionalModels.append((path, try makeReader().model(at: path)))
        }

        var models: [URL?: Model] = Dictionary(uniqueKeysWithValues: additionalModels)
        models[nil] = rootModel
        let staticModels = models

        let references = try rootModel.build.items.map {
            ($0, try Self.meshObjectsReferences(for: $0, with: staticModels))
        }

        let allRefs = Set(references.flatMap(\.1).map(\.reference))
        let orderedModelPaths = Array(Set(allRefs.map(\.modelPath)))

        var meshesByReference: [MeshObjectReference.ObjectReference: LoadedMesh] = [:]
        meshesByReference.reserveCapacity(allRefs.count)
        for reference in allRefs {
            guard let model = staticModels[reference.modelPath],
                  let modelIndex = orderedModelPaths.firstIndex(of: reference.modelPath),
                  let object = model.resources.resource(for: reference.objectID) as? Object,
                  case .mesh(let mesh) = object.content
            else { preconditionFailure() }

            meshesByReference[reference] = LoadedMesh(mesh: mesh, modelIndex: modelIndex)
        }

        var indexedMeshes: [LoadedMesh] = []
        let meshIndexByReference = meshesByReference.mapValues { mesh in
            let index = indexedMeshes.count
            indexedMeshes.append(mesh)
            return index
        }

        let orderedModels = orderedModelPaths.compactMap { models[$0] }

        self.init(rootModel: rootModel, models: orderedModels, meshes: indexedMeshes, items: references.map { item, references in
            guard let rootObject = models[item.path]?.resources.resource(for: item.objectID) as? Object else {
                preconditionFailure()
            }
            return LoadedItem(item: item, rootObject: rootObject, components: references.map { reference in
                guard let meshIndex = meshIndexByReference[reference.reference] else { preconditionFailure() }
                return LoadedComponent(
                    meshIndex: meshIndex,
                    transforms: reference.transforms,
                    propertyGroupID: reference.propertyGroupID,
                    propertyIndex: reference.propertyIndex,
                    names: reference.names,
                    partNumbers: reference.partNumbers
                )
            })
        })
    }

    private init(rootModel: Model, models: [Model], meshes: [LoadedMesh], items: [LoadedItem]) {
        self.rootModel = rootModel
        self.models = models
        self.meshes = meshes
        self.items = items
    }

    private static func meshObjectReferences(
        for objectID: ResourceID,
        in modelPath: URL?,
        with models: [URL?: Model],
        propertyGroupID: ResourceID?,
        propertyIndex: ResourceIndex?
    ) throws -> [MeshObjectReference] {
        guard let model = models[modelPath],
              let object = model.resources.resource(for: objectID) as? Object
        else {
            throw LoadingError.objectNotFound(modelPath: modelPath, objectID)
        }

        let resolvedPropertyGroupID = object.propertyGroupID ?? propertyGroupID
        let resolvedPropertyIndex = object.propertyIndex ?? propertyIndex

        switch object.content {
        case .mesh:
            return [MeshObjectReference(
                id: objectID,
                in: modelPath,
                propertyGroupID: resolvedPropertyGroupID,
                propertyIndex: resolvedPropertyIndex,
                name: object.name,
                partNumber: object.partNumber
            )]

        case .components(let components):
            return try components.flatMap { component in
                try meshObjectReferences(
                    for: component.objectID,
                    in: component.path,
                    with: models,
                    propertyGroupID: resolvedPropertyGroupID,
                    propertyIndex: resolvedPropertyIndex
                )
                .map { $0.prepending(transform: component.transform, name: object.name, partNumber: object.partNumber) }
            }
        }
    }

    private static func meshObjectsReferences(for item: Item, with models: [URL?: Model]) throws -> [MeshObjectReference] {
        try meshObjectReferences(for: item.objectID, in: item.path, with: models, propertyGroupID: nil, propertyIndex: nil)
            .map { $0.prepending(transform: item.transform, partNumber: item.partNumber) }
    }

    struct LoadedMesh {
        let mesh: Mesh
        let modelIndex: Int
    }

    struct LoadedItem {
        let item: Item
        let rootObject: Object
        let components: [LoadedComponent]
    }

    struct LoadedComponent {
        let meshIndex: Int
        let transforms: [Matrix3D]
        let propertyGroupID: ResourceID?
        let propertyIndex: ResourceIndex?
        let names: [String]
        let partNumbers: [String]
    }

    enum LoadingError: Error {
        case objectNotFound(modelPath: URL?, ResourceID)
    }
}

private struct MeshObjectReference {
    let reference: ObjectReference
    let transforms: [Matrix3D]
    let propertyGroupID: ResourceID?
    let propertyIndex: ResourceIndex?
    let names: [String]
    let partNumbers: [String]

    struct ObjectReference: Hashable {
        let modelPath: URL?
        let objectID: ResourceID
    }

    private init(
        reference: ObjectReference,
        transforms: [Matrix3D] = [],
        propertyGroupID: ResourceID?,
        propertyIndex: ResourceIndex?,
        names: [String],
        partNumbers: [String]
    ) {
        self.reference = reference
        self.transforms = transforms
        self.propertyGroupID = propertyGroupID
        self.propertyIndex = propertyIndex
        self.names = names
        self.partNumbers = partNumbers
    }

    init(
        id objectID: ResourceID,
        in modelPath: URL?,
        propertyGroupID: ResourceID?,
        propertyIndex: ResourceIndex?,
        name: String?,
        partNumber: String?
    ) {
        self.init(
            reference: ObjectReference(modelPath: modelPath, objectID: objectID),
            transforms: [],
            propertyGroupID: propertyGroupID,
            propertyIndex: propertyIndex,
            names: name.map { [$0] } ?? [],
            partNumbers: partNumber.map { [$0] } ?? []
        )
    }

    func prepending(transform: Matrix3D? = nil, name: String? = nil, partNumber: String? = nil) -> MeshObjectReference {
        MeshObjectReference(
            reference: reference,
            transforms: (transform.map { [$0] } ?? []) + transforms,
            propertyGroupID: propertyGroupID,
            propertyIndex: propertyIndex,
            names: name.map { [$0] + self.names } ?? names,
            partNumbers: partNumber.map { [$0] + self.partNumbers } ?? partNumbers
        )
    }
}
