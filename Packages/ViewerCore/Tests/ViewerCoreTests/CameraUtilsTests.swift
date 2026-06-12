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

    private func matricesEqual(_ a: float4x4, _ b: float4x4) -> Bool {
        (0..<4).allSatisfy { col in
            Double(a[col].x) ≈ Double(b[col].x)
            && Double(a[col].y) ≈ Double(b[col].y)
            && Double(a[col].z) ≈ Double(b[col].z)
            && Double(a[col].w) ≈ Double(b[col].w)
        }
    }
}

private extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}
