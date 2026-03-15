import Foundation
import SceneKit
import simd

// MARK: - Camera Transform

extension float4x4 {
    public init(lookingFrom position: simd_float3, at target: simd_float3) {
        let worldUp = simd_float3(0, 0, 1)
        var forward = target - position
        if simd_length_squared(forward) < 1.0e-12 {
            self = matrix_identity_float4x4
            return
        }
        forward = simd_normalize(forward)

        var right = simd_cross(forward, worldUp)
        if simd_length_squared(right) < 1.0e-6 {
            right = simd_dot(forward, worldUp) > 0
                ? simd_float3(-1, 0, 0)
                : simd_float3(1, 0, 0)
        }
        right = simd_normalize(right)

        self = float4x4(columns: (
            simd_float4(right, 0),
            simd_float4(simd_normalize(simd_cross(right, forward)), 0),
            simd_float4(-forward, 0),
            simd_float4(position, 1)
        ))
    }
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
