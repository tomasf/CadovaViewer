import Foundation
import ThreeMF
import SceneKit

enum Material {
    case vertexColors (Color, Color, Color)
    case pbr (PBRMaterial)

    var isFullyTransparent: Bool {
        if case let .vertexColors(color, color2, color3) = self {
            color.isFullyTransparent && color2.isFullyTransparent && color3.isFullyTransparent
        } else {
            false
        }
    }

    var colorValues: [Color]? {
        if case let .vertexColors(color, color2, color3) = self {
            [color, color2, color3]
        } else {
            nil
        }
    }
}

struct PBRMaterial: Hashable {
    let diffuse: Color
    let metallicness: Double
    let roughness: Double
    let name: String?

    var scnMaterial: SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = diffuse.nsColor
        material.metalness.contents = metallicness as NSNumber
        material.roughness.contents = roughness as NSNumber
        material.name = name
        if !diffuse.isOpaque {
            material.transparencyMode = .dualLayer
        }
        material.emission.intensity = 0
        return material
    }

}

extension ThreeMF.Color {
    var scnVector4: SCNVector4 {
        func sRGB8bToLinear(_ int: UInt8) -> Double {
            let d = Double(int) / 255.0
            return d < 0.04045 ? d * 0.0773993808 : pow(d * 0.9478672986 + 0.0521327014, 2.4)
        }

        return SCNVector4(sRGB8bToLinear(red), sRGB8bToLinear(green), sRGB8bToLinear(blue), Double(alpha) / 255.0)
    }

    var nsColor: NSColor {
        .init(srgbRed: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0, alpha: Double(alpha) / 255.0)
    }

    static let white = Self(red: 0xFF, green: 0xFF, blue: 0xFF)

    var isFullyTransparent: Bool {
        alpha == 0
    }
}

extension ThreeMF.Model {
    func colorGroup(for resourceID: ResourceID) -> ColorGroup? {
        guard let match = resources.resource(for: resourceID) as? ColorGroup else {
            return nil
        }
        return match
    }

    func color(for propertyReference: PropertyReference) -> (color: Color, displayProperties: PropertyReference?)? {
        let group = resources.resource(for: propertyReference.groupID)

        if let colorGroup = group as? ColorGroup {
            let display = colorGroup.displayPropertiesID.map { PropertyReference(groupID: $0, index: propertyReference.index) }
            guard let color = colorGroup.colors[safe: propertyReference.index] else { return nil }
            return (color, display)

        } else if let baseMaterialGroup = group as? BaseMaterialGroup {
            let display = baseMaterialGroup.displayPropertiesID.map { PropertyReference(groupID: $0, index: propertyReference.index) }
            guard let color = baseMaterialGroup.properties[safe: propertyReference.index]?.displayColor else { return nil }
            return (color, display)

        } else {
            return nil
        }
    }

    func pbrMaterial(for property: PropertyReference, baseColor: Color) -> PBRMaterial? {
        guard let group = resources.resource(for: property.groupID),
              let displayProperties = group as? MetallicDisplayProperties,
              let item = displayProperties.metallics[safe: property.index]
        else {
            return nil
        }

        return PBRMaterial(diffuse: baseColor, metallicness: item.metallicness, roughness: item.roughness, name: item.name)
    }

    func material(for triangle: Mesh.Triangle, inheritedProperty: PartialPropertyReference) -> Material? {
        guard let refs = triangle.resolvedProperties(inheritedProperty: inheritedProperty) else {
            return nil
        }

        if refs.count == 3 {
            guard let colors = refs.map({ color(for: $0)?.color }) as? [Color] else {
                return nil
            }
            return .vertexColors(colors[0], colors[1], colors[2])

        } else if refs.count == 1 {
            guard let (color, displayPropsID) = color(for: refs[0]) else { return nil }
            if let displayPropsID, let pbr = pbrMaterial(for: displayPropsID, baseColor: color) {
                return .pbr(pbr)
            } else {
                return .vertexColors(color, color, color)
            }
        } else {
            return nil
        }
    }
}

struct PartialPropertyReference {
    let groupID: ResourceID?
    let index: ResourceIndex?
}

extension Mesh.Triangle {
    func resolvedProperties(inheritedProperty: PartialPropertyReference) -> [PropertyReference]? {
        guard let groupID = propertyGroup ?? inheritedProperty.groupID else {
            return nil
        }

        switch propertyIndex {
        case .perVertex (let p1, let p2, let p3):
            return [p1, p2, p3].map { PropertyReference(groupID: groupID, index: $0) }

        case .uniform (let index):
            return [PropertyReference(groupID: groupID, index: index)]

        case .none:
            if let index = inheritedProperty.index {
                return [PropertyReference(groupID: groupID, index: index)]
            } else {
                return nil
            }
        }
    }
}
