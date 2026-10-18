import Testing
import simd
@testable import ViewerCore

struct CameraUtilsTests {
    @Test func `a degenerate look (eye equals target) returns the identity`() {
        let m = float4x4(lookingFrom: simd_float3(3, 3, 3), at: simd_float3(3, 3, 3))
        #expect(matricesEqual(m, matrix_identity_float4x4))
    }

    @Test func `the basis columns are orthonormal`() {
        let m = float4x4(lookingFrom: simd_float3(10, -4, 7), at: simd_float3(-2, 5, 1))
        let x = m.columns.0.xyz, y = m.columns.1.xyz, z = m.columns.2.xyz
        #expect(Double(simd_length(x)) ≈ 1)
        #expect(Double(simd_length(y)) ≈ 1)
        #expect(Double(simd_length(z)) ≈ 1)
        #expect(Double(simd_dot(x, y)) ≈ 0)
        #expect(Double(simd_dot(x, z)) ≈ 0)
        #expect(Double(simd_dot(y, z)) ≈ 0)
    }

    @Test func `the translation column holds the eye position`() {
        let eye = simd_float3(10, -4, 7)
        let m = float4x4(lookingFrom: eye, at: simd_float3(-2, 5, 1))
        #expect(Double(m.columns.3.x) ≈ 10)
        #expect(Double(m.columns.3.y) ≈ -4)
        #expect(Double(m.columns.3.z) ≈ 7)
        #expect(Double(m.columns.3.w) ≈ 1)
    }

    @Test func `negative z axis points from the eye toward the target`() {
        let eye = simd_float3(0, 0, 0)
        let target = simd_float3(0, 10, 0)
        let m = float4x4(lookingFrom: eye, at: target)
        let forward = -m.columns.2.xyz
        let expected = simd_normalize(target - eye)
        #expect(Double(simd_dot(forward, expected)) ≈ 1)
    }

    @Test func `looking straight up still yields a finite orthonormal basis`() {
        // forward is parallel to the world-up axis (0,0,1) → the gimbal fallback.
        let m = float4x4(lookingFrom: simd_float3(0, 0, 0), at: simd_float3(0, 0, 5))
        let x = m.columns.0.xyz, y = m.columns.1.xyz, z = m.columns.2.xyz
        #expect(x.x.isFinite && y.y.isFinite && z.z.isFinite)
        #expect(Double(simd_length(x)) ≈ 1)
        #expect(Double(simd_length(y)) ≈ 1)
        #expect(Double(simd_dot(x, y)) ≈ 0)
    }

    @Test func `view presets cover every case with stable titles`() {
        #expect(ViewPreset.allCases.count == 7)
        #expect(ViewPreset.isometric.title == "Iso")
        #expect(ViewPreset.front.title == "Front")
        #expect(ViewPreset.back.title == "Back")
        #expect(ViewPreset.left.title == "Left")
        #expect(ViewPreset.right.title == "Right")
        #expect(ViewPreset.top.title == "Top")
        #expect(ViewPreset.bottom.title == "Bottom")
    }

    @Test(arguments: ViewPreset.allCases)
    func `each preset's angles reproduce its view axis`(preset: ViewPreset) {
        let fromAngles = preset.direction.axis
        #expect(fromAngles.x ≈ preset.axis.x)
        #expect(fromAngles.y ≈ preset.axis.y)
        #expect(fromAngles.z ≈ preset.axis.z)
    }

    @Test func `view direction axes are unit length and follow the angle conventions`() {
        let direction = ViewDirection(azimuth: 30, elevation: 20)
        #expect(simd_length(direction.axis) ≈ 1)
        // Positive azimuth swings the camera from the front (−Y) toward the right (+X).
        #expect(direction.axis.x > 0 && direction.axis.y < 0)
        // Positive elevation raises the camera above the horizontal plane.
        #expect(direction.axis.z ≈ sin(20 * .pi / 180))
    }

    private func matricesEqual(_ a: float4x4, _ b: float4x4) -> Bool {
        (0..<4).allSatisfy { col in
            Double(a[col].x) ≈ Double(b[col].x)
            && Double(a[col].y) ≈ Double(b[col].y)
            && Double(a[col].z) ≈ Double(b[col].z)
            && Double(a[col].w) ≈ Double(b[col].w)
        }
    }

    /// The largest on-screen offset of any box corner, relative to the edge of a perspective camera's
    /// view (1 = exactly at the edge), for a camera on `axis` at `distance` from `center`.
    private func perspectiveFit(
        _ box: (min: SIMD3<Double>, max: SIMD3<Double>),
        center: SIMD3<Double>,
        axis: SIMD3<Double>,
        distance: Double,
        framing: BoundingBoxFraming,
        fieldOfViewDegrees: Double,
        aspectRatio: Double
    ) -> Double {
        let tanHalfFov = tan(fieldOfViewDegrees / 2 * .pi / 180)
        let camera = center + axis * distance
        var fit = 0.0
        for x in [box.min.x, box.max.x] {
            for y in [box.min.y, box.max.y] {
                for z in [box.min.z, box.max.z] {
                    let toCorner = SIMD3(x, y, z) - camera
                    let depth = -simd_dot(toCorner, axis)
                    let vertical = abs(simd_dot(toCorner, framing.up)) / depth / tanHalfFov
                    let horizontal = abs(simd_dot(toCorner, framing.right)) / depth / (tanHalfFov * aspectRatio)
                    fit = max(fit, vertical, horizontal)
                }
            }
        }
        return fit
    }

    @Test func `the perspective distance keeps every corner in view when a long box is seen end-on`() {
        let box = (min: SIMD3<Double>(0, -5, 0), max: SIMD3<Double>(120, 5, 16))
        let center = (box.min + box.max) / 2
        let axis = simd_normalize(SIMD3<Double>(-0.9, -0.3, 0.4))
        let fov = 30.0, aspect = 0.8

        let framing = frameBoundingBox(
            axis: axis, boundingBox: box, center: center,
            fieldOfViewDegrees: fov, aspectRatio: aspect, margin: 1
        )
        func fit(at distance: Double) -> Double {
            perspectiveFit(box, center: center, axis: axis, distance: distance, framing: framing,
                           fieldOfViewDegrees: fov, aspectRatio: aspect)
        }

        // The parallel-projection distance lets the near end run off screen, which is the case the
        // perspective distance exists for; at the perspective distance the tightest corner touches
        // the edge exactly
        #expect(fit(at: framing.distance) > 1.1)
        #expect(fit(at: framing.perspectiveDistance) ≈ 1)
    }
}

private extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}
