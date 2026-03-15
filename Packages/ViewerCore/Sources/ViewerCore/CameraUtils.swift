import Foundation
import SceneKit
import AppKit
import simd

// MARK: - Camera Transform

public func makeCameraTransform(position: simd_float3, target: simd_float3) -> float4x4 {
    let worldUp = simd_float3(0, 0, 1)
    var forward = target - position
    if simd_length_squared(forward) < 1.0e-12 {
        return matrix_identity_float4x4
    }
    forward = simd_normalize(forward)

    var right = simd_cross(forward, worldUp)
    if simd_length_squared(right) < 1.0e-6 {
        right = simd_dot(forward, worldUp) > 0
            ? simd_float3(-1, 0, 0)
            : simd_float3(1, 0, 0)
    }
    right = simd_normalize(right)

    return float4x4(columns: (
        simd_float4(right, 0),
        simd_float4(simd_normalize(simd_cross(right, forward)), 0),
        simd_float4(-forward, 0),
        simd_float4(position, 1)
    ))
}

// MARK: - Default Lighting

public func setupDefaultLighting(in scene: SCNScene) {
    let ambientLight = SCNLight()
    ambientLight.type = .ambient
    ambientLight.intensity = 30
    let ambientLightNode = SCNNode()
    ambientLightNode.light = ambientLight
    scene.rootNode.addChildNode(ambientLightNode)

    let directionalLight = SCNLight()
    directionalLight.type = .directional
    directionalLight.intensity = 500
    directionalLight.color = NSColor.white
    directionalLight.castsShadow = false
    let directionalLightNode = SCNNode()
    directionalLightNode.light = directionalLight
    directionalLightNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
    scene.rootNode.addChildNode(directionalLightNode)

    let fillLight = SCNLight()
    fillLight.type = .directional
    fillLight.intensity = 200
    fillLight.color = NSColor.white
    let fillLightNode = SCNNode()
    fillLightNode.light = fillLight
    fillLightNode.eulerAngles = SCNVector3(Float.pi / 6, -Float.pi / 3, 0)
    scene.rootNode.addChildNode(fillLightNode)
}

// MARK: - View Presets

public enum ViewPreset: Int, CaseIterable {
    case isometric
    case front
    case back
    case left
    case right
    case top
    case bottom

    public var title: String {
        switch self {
        case .isometric: return "Iso"
        case .front: return "Front"
        case .back: return "Back"
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
}
