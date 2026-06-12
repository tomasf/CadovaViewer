import Testing
import SceneKit
@testable import CadovaViewer

struct SCNMatrix4CodingTests {
    private func arbitraryMatrix() -> SCNMatrix4 {
        SCNMatrix4(
            m11: 1, m12: 2, m13: 3, m14: 4,
            m21: 5, m22: 6, m23: 7, m24: 8,
            m31: 9, m32: 10, m33: 11, m34: 12,
            m41: 13, m42: 14, m43: 15, m44: 16
        )
    }

    @Test func `the coding wrapper preserves the matrix`() {
        let matrix = arbitraryMatrix()
        #expect(SCNMatrix4.CodingWrapper(matrix).scnMatrix4 ≈ matrix)
    }

    @Test func `the coding wrapper survives a json round trip`() throws {
        let matrix = arbitraryMatrix()
        let data = try JSONEncoder().encode(SCNMatrix4.CodingWrapper(matrix))
        let decoded = try JSONDecoder().decode(SCNMatrix4.CodingWrapper.self, from: data)
        #expect(decoded.scnMatrix4 ≈ matrix)
    }
}
