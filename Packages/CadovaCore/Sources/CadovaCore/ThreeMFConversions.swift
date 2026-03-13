import Foundation
import ThreeMF
import SceneKit
import AppKit

// MARK: - Matrix and Vector Conversions

extension ThreeMF.Matrix3D {
    public var scnMatrix: SCNMatrix4 {
        let v = values
        return SCNMatrix4(
            m11: v[0][0], m12: v[0][1], m13: v[0][2], m14: 0,
            m21: v[1][0], m22: v[1][1], m23: v[1][2], m24: 0,
            m31: v[2][0], m32: v[2][1], m33: v[2][2], m34: 0,
            m41: v[3][0], m42: v[3][1], m43: v[3][2], m44: 1
        )
    }
}

extension ThreeMF.Mesh.Vertex {
    public var scnVector3: SCNVector3 {
        .init(x, y, z)
    }

    public var simd: SIMD3<Double> {
        .init(x, y, z)
    }
}

extension ThreeMF.Item {
    public var scnTransform: SCNMatrix4 {
        transform?.scnMatrix ?? SCNMatrix4Identity
    }
}

extension ThreeMF.Component {
    public var scnTransform: SCNMatrix4 {
        transform?.scnMatrix ?? SCNMatrix4Identity
    }
}

// MARK: - Materials

public enum Material {
    case vertexColors (ThreeMF.Color, ThreeMF.Color, ThreeMF.Color)
    case pbr (PBRMaterial)

    public var isFullyTransparent: Bool {
        if case let .vertexColors(color, color2, color3) = self {
            color.isFullyTransparent && color2.isFullyTransparent && color3.isFullyTransparent
        } else {
            false
        }
    }

    public var colorValues: [ThreeMF.Color]? {
        if case let .vertexColors(color, color2, color3) = self {
            [color, color2, color3]
        } else {
            nil
        }
    }
}

public struct PBRMaterial: Hashable {
    public let diffuse: ThreeMF.Color
    public let metallicness: Double
    public let roughness: Double
    public let name: String?

    public init(diffuse: ThreeMF.Color, metallicness: Double, roughness: Double, name: String?) {
        self.diffuse = diffuse
        self.metallicness = metallicness
        self.roughness = roughness
        self.name = name
    }

    public var scnMaterial: SCNMaterial {
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
    public var scnVector4: SCNVector4 {
        func sRGB8bToLinear(_ int: UInt8) -> Double {
            let d = Double(int) / 255.0
            return d < 0.04045 ? d * 0.0773993808 : pow(d * 0.9478672986 + 0.0521327014, 2.4)
        }

        return SCNVector4(sRGB8bToLinear(red), sRGB8bToLinear(green), sRGB8bToLinear(blue), Double(alpha) / 255.0)
    }

    public var nsColor: NSColor {
        .init(srgbRed: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0, alpha: Double(alpha) / 255.0)
    }

    public static let white = Self(red: 0xFF, green: 0xFF, blue: 0xFF)

    public var isFullyTransparent: Bool {
        alpha == 0
    }

    public var isOpaque: Bool {
        alpha == 255
    }
}

extension ThreeMF.Model {
    public func colorGroup(for resourceID: ResourceID) -> ColorGroup? {
        guard let match = resources.resource(for: resourceID) as? ColorGroup else {
            return nil
        }
        return match
    }

    public func color(for propertyReference: PropertyReference) -> (color: ThreeMF.Color, displayProperties: PropertyReference?)? {
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

    public func pbrMaterial(for property: PropertyReference, baseColor: ThreeMF.Color) -> PBRMaterial? {
        guard let group = resources.resource(for: property.groupID),
              let displayProperties = group as? MetallicDisplayProperties,
              let item = displayProperties.metallics[safe: property.index]
        else {
            return nil
        }

        return PBRMaterial(diffuse: baseColor, metallicness: item.metallicness, roughness: item.roughness, name: item.name)
    }

    public func material(for triangle: Mesh.Triangle, inheritedProperty: PartialPropertyReference) -> Material? {
        guard let refs = triangle.resolvedProperties(inheritedProperty: inheritedProperty) else {
            return nil
        }

        if refs.count == 3 {
            guard let colors = refs.map({ color(for: $0)?.color }) as? [ThreeMF.Color] else {
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

public struct PartialPropertyReference {
    public let groupID: ResourceID?
    public let index: ResourceIndex?

    public init(groupID: ResourceID?, index: ResourceIndex?) {
        self.groupID = groupID
        self.index = index
    }
}

extension Mesh.Triangle {
    public func resolvedProperties(inheritedProperty: PartialPropertyReference) -> [PropertyReference]? {
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
