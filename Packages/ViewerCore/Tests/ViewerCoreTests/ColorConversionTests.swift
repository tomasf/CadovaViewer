import Testing
import SceneKit
import ThreeMF
@testable import ViewerCore

struct ColorConversionTests {
    @Test func `opaque white converts to a unit linear vector`() {
        let v = ThreeMF.Color(red: 255, green: 255, blue: 255, alpha: 255).scnVector4
        #expect(v ≈ SCNVector4(1, 1, 1, 1))
    }

    @Test func `black converts to a zero linear vector`() {
        let v = ThreeMF.Color(red: 0, green: 0, blue: 0, alpha: 255).scnVector4
        #expect(v ≈ SCNVector4(0, 0, 0, 1))
    }

    @Test func `mid grey uses the sRGB gamma branch`() {
        // 128/255 → linear ≈ 0.2158 via the pow() branch.
        let v = ThreeMF.Color(red: 128, green: 128, blue: 128, alpha: 255).scnVector4
        #expect(v.x ≈ 0.2158)
        #expect(v.y ≈ 0.2158)
        #expect(v.z ≈ 0.2158)
    }

    @Test func `near-black uses the linear sRGB branch`() {
        // 10/255 = 0.0392 < 0.04045 → linear segment: 0.0392 * 0.0773993808.
        let v = ThreeMF.Color(red: 10, green: 0, blue: 0, alpha: 255).scnVector4
        #expect(v.x ≈ 0.003035)
    }

    @Test func `alpha passes through linearly`() {
        let v = ThreeMF.Color(red: 0, green: 0, blue: 0, alpha: 128).scnVector4
        let expectedAlpha = 128.0 / 255.0
        #expect(v.w ≈ expectedAlpha)
    }

    @Test func `ns color preserves each channel`() {
        let color = ThreeMF.Color(red: 51, green: 102, blue: 204, alpha: 255).nsColor
        let red = 51.0 / 255.0, green = 102.0 / 255.0, blue = 204.0 / 255.0
        #expect(Double(color.redComponent) ≈ red)
        #expect(Double(color.greenComponent) ≈ green)
        #expect(Double(color.blueComponent) ≈ blue)
        #expect(Double(color.alphaComponent) ≈ 1)
    }

    @Test func `opacity flags reflect the alpha channel`() {
        #expect(ThreeMF.Color(red: 0, green: 0, blue: 0, alpha: 255).isOpaque)
        #expect(!ThreeMF.Color(red: 0, green: 0, blue: 0, alpha: 254).isOpaque)
        #expect(ThreeMF.Color(red: 9, green: 9, blue: 9, alpha: 0).isFullyTransparent)
        #expect(!ThreeMF.Color(red: 9, green: 9, blue: 9, alpha: 1).isFullyTransparent)
    }

    @Test func `the white constant is fully opaque white`() {
        let white = ThreeMF.Color.white
        #expect(white.red == 255 && white.green == 255 && white.blue == 255)
        #expect(white.isOpaque)
    }
}
