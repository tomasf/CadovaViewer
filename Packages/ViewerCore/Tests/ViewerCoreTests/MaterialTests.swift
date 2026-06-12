import Testing
import ThreeMF
@testable import ViewerCore

struct MaterialTests {
    private let red = ThreeMF.Color(red: 255, green: 0, blue: 0)
    private let green = ThreeMF.Color(red: 0, green: 255, blue: 0)
    private let blue = ThreeMF.Color(red: 0, green: 0, blue: 255)
    private let clear = ThreeMF.Color(red: 0, green: 0, blue: 0, alpha: 0)

    @Test func `vertex-colors material is transparent only when every color is clear`() {
        #expect(Material.vertexColors(clear, clear, clear).isFullyTransparent)
        #expect(!Material.vertexColors(clear, red, clear).isFullyTransparent)
        #expect(!Material.vertexColors(red, green, blue).isFullyTransparent)
    }

    @Test func `pbr material is never reported as fully transparent`() {
        let pbr = PBRMaterial(diffuse: clear, metallicness: 0, roughness: 1, name: nil)
        #expect(!Material.pbr(pbr).isFullyTransparent)
    }

    @Test func `colorValues returns the three corner colors for vertex colors`() {
        let values = Material.vertexColors(red, green, blue).colorValues
        #expect(values == [red, green, blue])
    }

    @Test func `colorValues is nil for a pbr material`() {
        let pbr = PBRMaterial(diffuse: red, metallicness: 0.5, roughness: 0.5, name: "steel")
        #expect(Material.pbr(pbr).colorValues == nil)
    }

    @Test func `pbr material is hashable by its fields`() {
        let a = PBRMaterial(diffuse: red, metallicness: 0.5, roughness: 0.2, name: "steel")
        let b = PBRMaterial(diffuse: red, metallicness: 0.5, roughness: 0.2, name: "steel")
        let c = PBRMaterial(diffuse: red, metallicness: 0.5, roughness: 0.9, name: "steel")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}
