import Foundation
import ThreeMF
import SceneKit

enum Material {
    case colors (Color, Color, Color)
    case complex (ComplexMaterial)

    var isFullyTransparent: Bool {
        if case let .colors(color, color2, color3) = self {
            color.isFullyTransparent && color2.isFullyTransparent && color3.isFullyTransparent
        } else {
            false
        }
    }

    var colorValues: [Color]? {
        if case let .colors(color, color2, color3) = self {
            [color, color2, color3]
        } else {
            nil
        }
    }
}

enum ComplexMaterial: Hashable {
    case metallic (diffuse: Color, metallicness: Double, roughness: Double, name: String?)
    case specular (diffuse: Color, specularColor: Color, glossiness: Double, name: String?)
}

extension ComplexMaterial {
    var scnMaterial: SCNMaterial {
        let material = SCNMaterial()
        switch self {
        case .metallic(let diffuse, let metallicness, let roughness, let name):
            material.lightingModel = .physicallyBased
            material.diffuse.contents = diffuse.nsColor
            material.metalness.contents = metallicness as NSNumber
            material.roughness.contents = roughness as NSNumber
            material.name = name
            if !diffuse.isOpaque {
                material.transparencyMode = .dualLayer
            }

        case .specular(let diffuse, let specularColor, let glossiness, let name):
            material.diffuse.contents = diffuse.nsColor
            material.specular.contents = specularColor.nsColor
            material.shininess = glossiness
            material.lightingModel = .blinn
            material.name = name
            if !diffuse.isOpaque {
                material.transparencyMode = .dualLayer
            }
        }

        material.emission.intensity = 0
        return material
    }
}

extension ThreeMF.Color {
    var scnVector4: SCNVector4 {
        .init(Double(red) / 255.0, Double(green) / 255.0, Double(blue) / 255.0, Double(alpha) / 255.0)
    }

    var nsColor: NSColor {
        .init(red: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0, alpha: Double(alpha) / 255.0)
    }

    static let white = Self.init(red: 0xFF, green: 0xFF, blue: 0xFF)

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

    func complexMaterial(for property: PropertyReference, baseColor: Color) -> ComplexMaterial? {
        guard let group = resources.resource(for: property.groupID) else {
            return nil
        }
        if let displayProperties = group as? MetallicDisplayProperties, let item = displayProperties.metallics[safe: property.index] {
            return .metallic(diffuse: baseColor, metallicness: item.metallicness, roughness: item.roughness, name: item.name)

        } else if let displayProperties = group as? SpecularDisplayProperties, let item = displayProperties.speculars[safe: property.index] {
            let (specularColor, glossiness) = item.effectiveValues
            return .specular(diffuse: baseColor, specularColor: specularColor, glossiness: glossiness, name: item.name)

        } else {
            return nil
        }
    }

    func material(for triangle: Mesh.Triangle, in object: Object) -> Material? {
        guard let refs = triangle.resolvedProperties(in: object) else {
            return nil
        }

        if refs.count == 3 {
            guard let colors = refs.map({ color(for: $0)?.color }) as? [Color] else {
                return nil
            }
            return .colors(colors[0], colors[1], colors[2])

        } else if refs.count == 1 {
            guard let (color, displayPropsID) = color(for: refs[0]) else { return nil }
            if let displayPropsID, let complex = complexMaterial(for: displayPropsID, baseColor: color) {
                return .complex(complex)
            } else {
                return .colors(color, color, color)
            }
        } else {
            return nil
        }
    }
}
