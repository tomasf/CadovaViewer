import Testing
import simd
@testable import CadovaViewer

struct SIMD4ComponentsTests {
    @Test func `xyz drops the w component`() {
        let v = SIMD4<Float>(1, 2, 3, 4)
        #expect(v.xyz == SIMD3<Float>(1, 2, 3))
    }
}
