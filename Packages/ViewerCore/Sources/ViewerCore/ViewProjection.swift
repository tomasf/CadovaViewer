import SceneKit
import simd

/// Reproduces `SCNSceneRenderer.projectPoint` with plain matrix math.
///
/// `projectPoint` is an Objective-C round trip into the renderer, which is fine for a handful of
/// points but far too slow for a whole model's worth — building a screen-space index of tens of
/// thousands of points costs tens of milliseconds that way. Capturing the camera once and
/// multiplying through simd makes the same batch effectively free.
///
/// Note that `SCNCamera.projectionTransform` does *not* account for the viewport's aspect ratio;
/// the matrix must come from `projectionTransform(withViewportSize:)` for the result to match.
public struct ViewProjection {
    private let viewProjection: simd_float4x4
    private let width: Float
    private let height: Float

    /// - Parameters:
    ///   - cameraTransform: The point-of-view node's `worldTransform`.
    ///   - projectionTransform: The camera's `projectionTransform(withViewportSize:)` for `viewportSize`.
    ///   - viewportSize: The renderer's size, in points.
    public init(cameraTransform: SCNMatrix4, projectionTransform: SCNMatrix4, viewportSize: CGSize) {
        viewProjection = simd_float4x4(projectionTransform) * simd_inverse(simd_float4x4(cameraTransform))
        width = Float(viewportSize.width)
        height = Float(viewportSize.height)
    }

    /// The point in view coordinates: points from the bottom-left corner, matching `projectPoint`.
    /// Nil for a point behind a perspective camera, where the projective divide would otherwise
    /// mirror it back into view as a plausible-looking screen position.
    ///
    /// Only x and y are reported, and there is deliberately no near/far clipping. A camera with
    /// `automaticallyAdjustsZRange` computes its depth range at render time without writing it
    /// back to `zNear`/`zFar`, so those properties — and hence the depth this matrix produces —
    /// can be wildly wrong while x and y stay exact (neither projection's x/y terms involve the
    /// depth range). Filtering on that depth silently rejects everything on screen. Callers that
    /// need depth should measure it against the camera in world space instead.
    public func project(_ point: SCNVector3) -> CGPoint? {
        let clip = viewProjection * SIMD4<Float>(Float(point.x), Float(point.y), Float(point.z), 1)
        // Perspective puts points behind the camera at negative w. An orthographic camera always
        // has w == 1 and no divide, so points behind it still project to a meaningful position.
        guard clip.w > 0 else { return nil }
        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        return CGPoint(x: CGFloat((ndc.x * 0.5 + 0.5) * width), y: CGFloat((ndc.y * 0.5 + 0.5) * height))
    }
}
