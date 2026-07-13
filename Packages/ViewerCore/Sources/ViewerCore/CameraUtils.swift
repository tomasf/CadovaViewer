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

extension SIMD4<Float> {
    fileprivate var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
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

    /// The outward view axis: a unit vector pointing from the model center toward the camera.
    public var axis: SIMD3<Double> {
        switch self {
        case .isometric:
            let isoAngle = 35.264 * (.pi / 180)
            return simd_normalize(SIMD3(-cos(isoAngle), -cos(isoAngle), sin(isoAngle)))
        case .front:  return SIMD3(0, -1, 0)
        case .back:   return SIMD3(0,  1, 0)
        case .left:   return SIMD3(-1, 0, 0)
        case .right:  return SIMD3( 1, 0, 0)
        case .top:    return SIMD3(0, 0,  1)
        case .bottom: return SIMD3(0, 0, -1)
        }
    }
}

// MARK: - Bounding Box Framing

/// The axes and camera placement needed to frame a bounding box, as computed by `frameBoundingBox`.
public struct BoundingBoxFraming {
    /// The camera's world-space right vector for this view.
    public let right: SIMD3<Double>
    /// The camera's world-space up vector for this view.
    public let up: SIMD3<Double>
    /// Half the world-height a perspective camera at `distance` shows across the full view height
    /// (i.e. the value SceneKit's `orthographicScale` needs to reproduce the same framing).
    public let orthographicScale: Double
    /// The distance from `center` (along the framing axis) the camera must sit at to fit the box.
    public let distance: Double
}

/// Computes the placement needed to frame a world-space bounding box viewed from `axis` (a unit
/// vector from `center` toward the camera), leaving `margin` extra headroom beyond the tightest fit
/// (1.5 = 50% headroom, matching the interactive viewport's default framing for view presets).
/// `aspectRatio` is the destination view/image's width divided by its height.
public func frameBoundingBox(
    axis: SIMD3<Double>,
    boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>),
    center: SIMD3<Double>,
    fieldOfViewDegrees: Double,
    aspectRatio: Double,
    margin: Double = 1.5
) -> BoundingBoxFraming {
    let (min, max) = boundingBox

    // Build a provisional orientation (distance-independent) so we know the camera's right/up
    // vectors, then project the 8 bbox corners onto them to get the true on-screen extents. This
    // handles every preset uniformly and works even when the model isn't centered on its bounding
    // sphere. The lookingFrom helper supplies a sane right/up fallback for axes parallel to world up.
    let orientation = float4x4(lookingFrom: SIMD3<Float>(center + axis), at: SIMD3<Float>(center))
    let right = SIMD3<Double>(orientation.columns.0.xyz)
    let up = SIMD3<Double>(orientation.columns.1.xyz)

    let corners: [SIMD3<Double>] = [
        SIMD3(min.x, min.y, min.z), SIMD3(min.x, min.y, max.z),
        SIMD3(min.x, max.y, min.z), SIMD3(min.x, max.y, max.z),
        SIMD3(max.x, min.y, min.z), SIMD3(max.x, min.y, max.z),
        SIMD3(max.x, max.y, min.z), SIMD3(max.x, max.y, max.z)
    ]

    var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
    var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
    for corner in corners {
        let diff = corner - center
        let u = simd_dot(diff, right)
        let v = simd_dot(diff, up)
        minU = Swift.min(minU, u); maxU = Swift.max(maxU, u)
        minV = Swift.min(minV, v); maxV = Swift.max(maxV, v)
    }

    var width = maxU - minU
    var height = maxV - minV
    if width <= 0 || height <= 0 || !width.isFinite || !height.isFinite {
        let boxExtent = simd_reduce_max(max - min)
        let fallbackExtent = boxExtent > 0 && boxExtent.isFinite ? boxExtent : 1
        width = fallbackExtent
        height = fallbackExtent
    }

    // orthoScale is half the world-height that fills the full view height, so fitting width needs
    // to account for the view's aspect ratio while fitting height doesn't.
    let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
    let fitWidthScale = width / 2 / safeAspectRatio
    let fitHeightScale = height / 2
    var orthoScale = Swift.max(fitWidthScale, fitHeightScale) * margin
    if orthoScale <= 0 || !orthoScale.isFinite {
        orthoScale = 1
    }

    // Place the camera at the distance that makes calculateOrthographicScale() (distance *
    // tan(fov/2), the value SceneKit actually uses for the ortho projection) reproduce exactly
    // orthoScale, so the framing isn't overridden. The same distance frames the model with matching
    // margin in perspective mode.
    let fovRadians = fieldOfViewDegrees * (.pi / 180.0)
    let tanHalfFov = tan(fovRadians / 2)
    let distance = tanHalfFov > 0 && orthoScale > 0 ? orthoScale / tanHalfFov : 1

    return BoundingBoxFraming(right: right, up: up, orthographicScale: orthoScale, distance: distance)
}
